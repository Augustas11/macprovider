package relayblind

import (
	"bytes"
	rb "github.com/augstar/macprovider-relayblind"
)

// Protocol types, constants, and functions live in the shared module.
// These aliases keep this package's callers on one implementation.

// types
type ConsumeResponse = rb.ConsumeResponse
type Envelope = rb.Envelope
type IdentityDirectory = rb.IdentityDirectory
type IdentityDirectoryEntry = rb.IdentityDirectoryEntry
type IdentityDirectoryEnvelope = rb.IdentityDirectoryEnvelope
type IdentityPin = rb.IdentityPin
type KeyRecord = rb.KeyRecord
type PostureStatement = rb.PostureStatement
type PrivacyEnrollmentClaim = rb.PrivacyEnrollmentClaim
type PrivacyFinal = rb.PrivacyFinal
type PrivacyFrame = rb.PrivacyFrame
type PrivacyKeyAttestation = rb.PrivacyKeyAttestation
type PrivacyKeyRecord = rb.PrivacyKeyRecord
type PrivacyStreamEvent = rb.PrivacyStreamEvent
type PrivacyStreamGate = rb.PrivacyStreamGate
type ReservationRequest = rb.ReservationRequest
type ReservationResponse = rb.ReservationResponse
type ResponseKeys = rb.ResponseKeys
type StatusRequest = rb.StatusRequest
type StatusResponse = rb.StatusResponse

// constants
const Algorithm = rb.Algorithm
const CachePolicyNoStore = rb.CachePolicyNoStore
const CapabilityJSONSchemaNonStrict = rb.CapabilityJSONSchemaNonStrict
const ConsumeVersion = rb.ConsumeVersion
const EndpointChatCompletions = rb.EndpointChatCompletions
const EndpointMessages = rb.EndpointMessages
const EndpointResponses = rb.EndpointResponses
const EnvelopeVersion = rb.EnvelopeVersion
const FailoverPolicyDisabled = rb.FailoverPolicyDisabled
const IdentityDirectoryDomain = rb.IdentityDirectoryDomain
const IdentityDirectoryEnvelopeVersion = rb.IdentityDirectoryEnvelopeVersion
const IdentityDirectorySourceEnrolled = rb.IdentityDirectorySourceEnrolled
const IdentityDirectorySourceOperatorPin = rb.IdentityDirectorySourceOperatorPin
const IdentityDirectoryVersion = rb.IdentityDirectoryVersion
const MaxEncryptedRequestBytes = rb.MaxEncryptedRequestBytes
const MaxIdentifierBytes = rb.MaxIdentifierBytes
const MaxIdentityDirectoryBytes = rb.MaxIdentityDirectoryBytes
const MaxIdentityDirectoryEntries = rb.MaxIdentityDirectoryEntries
const MaxIdentityDirectoryFutureSkew = rb.MaxIdentityDirectoryFutureSkew
const MaxIdentityDirectoryTTL = rb.MaxIdentityDirectoryTTL
const MaxKeyFutureSkew = rb.MaxKeyFutureSkew
const MaxKeyLifetime = rb.MaxKeyLifetime
const MaxModelCount = rb.MaxModelCount
const MaxPrivacyFramePlaintext = rb.MaxPrivacyFramePlaintext
const MaxPrivacyKeyLifetimeSeconds = rb.MaxPrivacyKeyLifetimeSeconds
const MaxPrivacyKeyRecordDigests = rb.MaxPrivacyKeyRecordDigests
const MaxPrivacyPostureResponseBytes = rb.MaxPrivacyPostureResponseBytes
const MinIdentityDirectoryTTL = rb.MinIdentityDirectoryTTL
const ModeRequired = rb.ModeRequired
const PinVersion = rb.PinVersion
const PrivacyAssurance = rb.PrivacyAssurance
const PrivacyAssuranceCodeBound = rb.PrivacyAssuranceCodeBound
const PrivacyAssuranceRequiredHeader = rb.PrivacyAssuranceRequiredHeader
const PrivacyClassV1 = rb.PrivacyClassV1
const PrivacyEnrollmentVersion = rb.PrivacyEnrollmentVersion
const PrivacyFinalStatusCancelled = rb.PrivacyFinalStatusCancelled
const PrivacyFinalStatusComplete = rb.PrivacyFinalStatusComplete
const PrivacyFinalStatusError = rb.PrivacyFinalStatusError
const PrivacyFinalVersion = rb.PrivacyFinalVersion
const PrivacyFrameObject = rb.PrivacyFrameObject
const PrivacyKeyAttestationDomain = rb.PrivacyKeyAttestationDomain
const PrivacyKeyAttestationVersion = rb.PrivacyKeyAttestationVersion
const PrivacyPostureDomain = rb.PrivacyPostureDomain
const PrivacyPostureVersion = rb.PrivacyPostureVersion
const PrivacyRejectAssuranceUnavailable = rb.PrivacyRejectAssuranceUnavailable
const PrivacyRejectBuyerCancelled = rb.PrivacyRejectBuyerCancelled
const PrivacyRejectCapabilityUnsupported = rb.PrivacyRejectCapabilityUnsupported
const PrivacyRejectClassNotConfigured = rb.PrivacyRejectClassNotConfigured
const PrivacyRejectCodeIdentityUnapproved = rb.PrivacyRejectCodeIdentityUnapproved
const PrivacyRejectDispatchUnavailable = rb.PrivacyRejectDispatchUnavailable
const PrivacyRejectKeyAttestationMismatch = rb.PrivacyRejectKeyAttestationMismatch
const PrivacyRejectKeyNotInPosture = rb.PrivacyRejectKeyNotInPosture
const PrivacyRejectKeyStaleOrRevoked = rb.PrivacyRejectKeyStaleOrRevoked
const PrivacyRejectKillSwitch = rb.PrivacyRejectKillSwitch
const PrivacyRejectLiveSessionUnavailable = rb.PrivacyRejectLiveSessionUnavailable
const PrivacyRejectMarkerMismatch = rb.PrivacyRejectMarkerMismatch
const PrivacyRejectModelNotPrivateCapable = rb.PrivacyRejectModelNotPrivateCapable
const PrivacyRejectModelNotServed = rb.PrivacyRejectModelNotServed
const PrivacyRejectOther = rb.PrivacyRejectOther
const PrivacyRejectPhaseConsume = rb.PrivacyRejectPhaseConsume
const PrivacyRejectPhaseDispatch = rb.PrivacyRejectPhaseDispatch
const PrivacyRejectPhaseReservation = rb.PrivacyRejectPhaseReservation
const PrivacyRejectPoolNoEligibleMember = rb.PrivacyRejectPoolNoEligibleMember
const PrivacyRejectPoolScopedRequest = rb.PrivacyRejectPoolScopedRequest
const PrivacyRejectPoolStateStale = rb.PrivacyRejectPoolStateStale
const PrivacyRejectPostureExpired = rb.PrivacyRejectPostureExpired
const PrivacyRejectPostureUnverified = rb.PrivacyRejectPostureUnverified
const PrivacyRejectProviderNotEnrolled = rb.PrivacyRejectProviderNotEnrolled
const PrivacyRejectProviderQuarantined = rb.PrivacyRejectProviderQuarantined
const PrivacyRejectProviderQuotaUnavailable = rb.PrivacyRejectProviderQuotaUnavailable
const PrivacyRejectProviderRejected = rb.PrivacyRejectProviderRejected
const PrivacyRejectReasonHeader = rb.PrivacyRejectReasonHeader
const PrivacyRejectRelayBlindUnavailable = rb.PrivacyRejectRelayBlindUnavailable
const PrivacyRejectReservationExpired = rb.PrivacyRejectReservationExpired
const PrivacyRejectReservationRejected = rb.PrivacyRejectReservationRejected
const PrivacyRejectSessionLost = rb.PrivacyRejectSessionLost
const PrivacyRejectSettlementPrerequisite = rb.PrivacyRejectSettlementPrerequisite
const PrivacyRejectSettlementSnapshotFailed = rb.PrivacyRejectSettlementSnapshotFailed
const PrivacyRejectSlotUnavailable = rb.PrivacyRejectSlotUnavailable
const PrivacyRejectStoreUnavailable = rb.PrivacyRejectStoreUnavailable
const PrivacyReservationVersion = rb.PrivacyReservationVersion
const PrivacyResponseEncryption = rb.PrivacyResponseEncryption
const PrivacyResponseKeyLabel = rb.PrivacyResponseKeyLabel
const PrivacyResponseNoncePrefixLabel = rb.PrivacyResponseNoncePrefixLabel
const PrivacyResponseObject = rb.PrivacyResponseObject
const PrivacyResponseVersion = rb.PrivacyResponseVersion
const PrivacyRuntimeSource = rb.PrivacyRuntimeSource
const PrivacySEBackendFile = rb.PrivacySEBackendFile
const PrivacySEBackendKeychain = rb.PrivacySEBackendKeychain
const PrivacyStreamDone = rb.PrivacyStreamDone
const PrivacyStreamFrame = rb.PrivacyStreamFrame
const PrivacyStreamUsage = rb.PrivacyStreamUsage
const ReservationVersion = rb.ReservationVersion
const RetryDoNotResubmit = rb.RetryDoNotResubmit
const SignatureAlgorithm = rb.SignatureAlgorithm
const StatusVersion = rb.StatusVersion

// variables
var ErrInvalidConsume = rb.ErrInvalidConsume
var ErrInvalidDirectory = rb.ErrInvalidDirectory
var ErrInvalidEnvelope = rb.ErrInvalidEnvelope
var ErrInvalidJSON = rb.ErrInvalidJSON
var ErrInvalidKeyRecord = rb.ErrInvalidKeyRecord
var ErrInvalidPin = rb.ErrInvalidPin
var ErrInvalidPrivacy = rb.ErrInvalidPrivacy
var ErrInvalidReservation = rb.ErrInvalidReservation
var ErrInvalidStatus = rb.ErrInvalidStatus

// functions
var DecodeBase64URLFixed = rb.DecodeBase64URLFixed
var DecodeClosed = rb.DecodeClosed
var DecodeSEPublicKey = rb.DecodeSEPublicKey
var DeriveResponseKeys = rb.DeriveResponseKeys
var DigestEnvelopeBytes = rb.DigestEnvelopeBytes
var EncodeBase64URL = rb.EncodeBase64URL
var NewSignedKeyRecord = rb.NewSignedKeyRecord
var NewSignedKeyRecordForFamilies = rb.NewSignedKeyRecordForFamilies
var NormalizePrivacyRejectReason = rb.NormalizePrivacyRejectReason
var OpenFrame = rb.OpenFrame
var ParseConsumeResponse = rb.ParseConsumeResponse
var ParseEnvelope = rb.ParseEnvelope
var ParseIdentityPin = rb.ParseIdentityPin
var ParseKeyRecord = rb.ParseKeyRecord
var ParsePostureStatement = rb.ParsePostureStatement
var ParsePrivacyEnrollmentClaim = rb.ParsePrivacyEnrollmentClaim
var ParsePrivacyFinal = rb.ParsePrivacyFinal
var ParsePrivacyFrame = rb.ParsePrivacyFrame
var ParsePrivacyKeyRecord = rb.ParsePrivacyKeyRecord
var ParseReservationRequest = rb.ParseReservationRequest
var ParseReservationResponse = rb.ParseReservationResponse
var ParseStatusRequest = rb.ParseStatusRequest
var ParseStatusResponse = rb.ParseStatusResponse
var PrivacyAssuranceKnown = rb.PrivacyAssuranceKnown
var PrivacyRejectPhaseKnown = rb.PrivacyRejectPhaseKnown
var PrivacyRejectReasons = rb.PrivacyRejectReasons
var PublicKeyFingerprint = rb.PublicKeyFingerprint
var ReadIdentityPin = rb.ReadIdentityPin
var RejectDuplicateJSONKeys = rb.RejectDuplicateJSONKeys
var RequiredCapabilities = rb.RequiredCapabilities
var RequiredCapabilitiesForFamily = rb.RequiredCapabilitiesForFamily
var RequiresNonStrictJSONSchema = rb.RequiresNonStrictJSONSchema
var ResponseAAD = rb.ResponseAAD
var SealFrame = rb.SealFrame
var SignIdentityDirectory = rb.SignIdentityDirectory
var ValidCDHash = rb.ValidCDHash
var ValidEndpointFamily = rb.ValidEndpointFamily
var ValidRequires = rb.ValidRequires
var ValidTeamID = rb.ValidTeamID
var ValidateKeyRenewal = rb.ValidateKeyRenewal
var ValidatePrivacyFrameSequence = rb.ValidatePrivacyFrameSequence
var ValidatePrivacyResponseBody = rb.ValidatePrivacyResponseBody
var VerifyIdentityDirectory = rb.VerifyIdentityDirectory
var VisibleASCII = rb.VisibleASCII
var WriteFrame = rb.WriteFrame
var WriteI64 = rb.WriteI64
var WriteU64 = rb.WriteU64

func decodeBase64URLFixed(value string, size int) ([]byte, error) {
	return rb.DecodeBase64URLFixed(value, size)
}

func decodeClosed(raw []byte, dst any, fields []string) error {
	return rb.DecodeClosed(raw, dst, fields)
}

func encodeBase64URL(value []byte) string { return rb.EncodeBase64URL(value) }

func rejectDuplicateJSONKeys(raw []byte) error {
	return rb.RejectDuplicateJSONKeys(raw)
}

func validCDHash(value string) bool { return rb.ValidCDHash(value) }

func validTeamID(value string) bool { return rb.ValidTeamID(value) }

func visibleASCII(value string, max int) bool { return rb.VisibleASCII(value, max) }

func writeFrame(dst *bytes.Buffer, value []byte) error { return rb.WriteFrame(dst, value) }

func writeI64(dst *bytes.Buffer, value int64) { rb.WriteI64(dst, value) }

func writeU64(dst *bytes.Buffer, value uint64) { rb.WriteU64(dst, value) }
