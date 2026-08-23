package poolmanifest

// SPEC-042-R011/R012 signed emergency lifecycle controls. This file keeps the
// control message pure and domain-separated from policy-core and authority-log
// signatures: a signed policy or authority entry cannot be replayed as a pool
// lifecycle command.

import (
	"bytes"
	"crypto/sha256"
	"errors"
)

const (
	emergencyLifecycleControlTag    = "macprovider/spec042/emergency-lifecycle-control/v2"
	emergencyLifecycleControlSigTag = "macprovider/spec042/emergency-lifecycle-control-sig/v2"

	EmergencyLifecyclePaused          = "paused"
	EmergencyLifecycleDraining        = "draining"
	EmergencyLifecycleRetired         = "retired"
	EmergencyLifecycleRevokeImmediate = "revoke_immediate"
)

var (
	errEmergencyControlAction       = errors.New("poolmanifest: emergency lifecycle action is not allowed")
	errEmergencyControlOperationID  = errors.New("poolmanifest: emergency lifecycle operation_id is required")
	errEmergencyControlPoolID       = errors.New("poolmanifest: emergency lifecycle pool_id mismatch")
	errEmergencyControlManifest     = errors.New("poolmanifest: emergency lifecycle manifest binding mismatch")
	errEmergencyControlDigestLen    = errors.New("poolmanifest: emergency lifecycle manifest_core_digest must be 32 bytes")
	errEmergencyControlWindow       = errors.New("poolmanifest: emergency lifecycle validity window must satisfy issued_at < expires_at")
	errEmergencyControlExpired      = errors.New("poolmanifest: emergency lifecycle control is expired or not yet valid")
	errEmergencyControlSignerSet    = errors.New("poolmanifest: emergency lifecycle signer set is not current")
	errEmergencyControlUnknownSet   = errors.New("poolmanifest: emergency lifecycle signer set not in authority log")
	errEmergencyControlEmptyHistory = errors.New("poolmanifest: emergency lifecycle snapshot has no accepted policy")
	errEmergencyControlProviderID   = errors.New("poolmanifest: emergency lifecycle target_provider_id is invalid for action")
)

// EmergencyLifecycleControl is the signed SPEC-042-R011/R012 command that can
// make a pool less routeable without local operator discretion. SignerSetVersion
// 0 means "manifest authority root issuer"; otherwise it must name the current
// operational signer set from the snapshot authority log.
type EmergencyLifecycleControl struct {
	PoolID             string
	ManifestVersion    uint64
	ManifestCoreDigest []byte
	SignerSetVersion   uint64
	OperationID        string
	Action             string
	TargetProviderID   string
	Reason             string
	IssuedAtUnix       uint64
	ExpiresAtUnix      uint64
}

func (c EmergencyLifecycleControl) CanonicalBytes() ([]byte, error) {
	if c.OperationID == "" {
		return nil, errEmergencyControlOperationID
	}
	if !validEmergencyLifecycleAction(c.Action) {
		return nil, errEmergencyControlAction
	}
	if c.Action == EmergencyLifecycleRevokeImmediate {
		if c.TargetProviderID == "" {
			return nil, errEmergencyControlProviderID
		}
	} else if c.TargetProviderID != "" {
		return nil, errEmergencyControlProviderID
	}
	if len(c.ManifestCoreDigest) != manifestCoreHashLen {
		return nil, errEmergencyControlDigestLen
	}
	if c.IssuedAtUnix >= c.ExpiresAtUnix {
		return nil, errEmergencyControlWindow
	}
	e := &encoder{}
	e.tag(emergencyLifecycleControlTag)
	e.str(c.PoolID)
	e.u64(c.ManifestVersion)
	e.bytesf(c.ManifestCoreDigest)
	e.u64(c.SignerSetVersion)
	e.str(c.OperationID)
	e.str(c.Action)
	e.str(c.TargetProviderID)
	e.str(c.Reason)
	e.u64(c.IssuedAtUnix)
	e.u64(c.ExpiresAtUnix)
	if e.err != nil {
		return nil, e.err
	}
	return e.buf, nil
}

func (c EmergencyLifecycleControl) Digest() ([]byte, error) {
	b, err := c.CanonicalBytes()
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(b)
	return sum[:], nil
}

func EmergencyLifecycleControlSigningMessage(controlDigest []byte) ([]byte, error) {
	if len(controlDigest) != manifestCoreHashLen {
		return nil, errAuthEntryHashLen
	}
	msg := make([]byte, 0, len(emergencyLifecycleControlSigTag)+manifestCoreHashLen)
	msg = append(msg, emergencyLifecycleControlSigTag...)
	msg = append(msg, controlDigest...)
	return msg, nil
}

// VerifyEmergencyLifecycleControl accepts iff the control is bound to the passed
// manifest snapshot, has a currently valid time window, and is signed either by
// the snapshot's root issuer (SignerSetVersion == 0) or by the snapshot's current
// operational signer set at threshold.
func VerifyEmergencyLifecycleControl(c EmergencyLifecycleControl, sigs []Signature, snapshot ManifestSnapshot, nowUnix uint64) error {
	digest, err := c.Digest()
	if err != nil {
		return err
	}
	if !(c.IssuedAtUnix <= nowUnix && nowUnix < c.ExpiresAtUnix) {
		return errEmergencyControlExpired
	}
	reconstructed, err := ReconstructPool(snapshot)
	if err != nil {
		return err
	}
	poolID, err := snapshot.IdentityCore.PoolID()
	if err != nil {
		return err
	}
	if c.PoolID != poolID {
		return errEmergencyControlPoolID
	}
	if len(snapshot.Policies) == 0 {
		return errEmergencyControlEmptyHistory
	}
	last := snapshot.Policies[len(snapshot.Policies)-1].SignedCore.Core
	lastDigest, err := last.ManifestCoreDigest()
	if err != nil {
		return err
	}
	if c.ManifestVersion != last.ManifestVersion || !bytes.Equal(c.ManifestCoreDigest, lastDigest) {
		return errEmergencyControlManifest
	}
	msg, err := EmergencyLifecycleControlSigningMessage(digest)
	if err != nil {
		return err
	}
	if c.SignerSetVersion == 0 {
		return verifyRootIssuerSig(snapshot.RootIssuerKey, msg, sigs)
	}
	if c.SignerSetVersion != reconstructed.AuthorityLog.CurrentVersion() {
		return errEmergencyControlSignerSet
	}
	ss, ok := reconstructed.AuthorityLog.SignerSet(c.SignerSetVersion)
	if !ok {
		return errEmergencyControlUnknownSet
	}
	if err := ss.Validate(); err != nil {
		return err
	}
	if ss.Revoked {
		return errSignerSetRevoked
	}
	if !(ss.NotBeforeUnix <= c.IssuedAtUnix && c.IssuedAtUnix < ss.ExpiresAtUnix) {
		return errSignerSetInactive
	}
	return verifyThresholdMessage(msg, sigs, ss)
}

func validEmergencyLifecycleAction(v string) bool {
	switch v {
	case EmergencyLifecyclePaused, EmergencyLifecycleDraining, EmergencyLifecycleRetired, EmergencyLifecycleRevokeImmediate:
		return true
	default:
		return false
	}
}
