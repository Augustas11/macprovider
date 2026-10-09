package poolmanifest

// SPEC-042-R015/R016 (#1816): pool-scoped model entries and creator-signed
// member attestations, carried as two named extensions of the v2 policy core
// (`pool_model_entries/v1`, `pool_attested_members/v1`). The extension bodies
// are trust-bearing core data: they sit inside the v2 digest and signature,
// so no new policy-core encoding is needed and a v2 core without them keeps
// its exact bytes. Nothing here creates a SPEC-010 catalog identity: a
// pool_model_id is authority only on routes for the pool whose id it embeds.

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strings"
)

// Implemented extension ids (SPEC-042-R001 extension_id grammar).
const (
	ExtensionPoolModelEntriesV1    = "pool_model_entries/v1"
	ExtensionPoolAttestedMembersV1 = "pool_attested_members/v1"
)

// Closed vocabularies and bounds (SPEC-042-R015/R016).
const (
	ArtifactHashAlgorithmGGUFFileV1         = "macprovider.gguf-file.v1"
	ArtifactHashAlgorithmSnapshotManifestV1 = "macprovider.snapshot-manifest.v1"
	PoolModelDisclosureClass                = "pool_attested_unverified"
	// RuntimeSourceNativeMLX is the native runtime. It is never listed in
	// runtime_allowlist (native is always allowed in a pool) but a
	// snapshot-manifest entry MAY name it in allowed_runtime_sources.
	RuntimeSourceNativeMLX = "mlx_cache"

	MaxPoolModelEntries     = 256
	MaxAttestedMembers      = 1024
	MaxPoolModelContext     = 1 << 20
	maxPoolModelIDBytes     = 91
	maxProviderAccountBytes = 128
)

var (
	poolModelIDPattern     = regexp.MustCompile(`^pool/([A-Za-z0-9_-]{22})/([a-z0-9][a-z0-9-]{0,62})$`)
	artifactHashPattern    = regexp.MustCompile(`^[0-9a-f]{64}$`)
	licenseRefPattern      = regexp.MustCompile(`^LicenseRef-[A-Za-z0-9][A-Za-z0-9.-]{0,63}$`)
	providerAccountPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:@-]{0,127}$`)
)

// pinnedSPDXLicenseIDs is the coordinator's pinned SPDX identifier registry
// for R015 entries: SPDX License List identifiers used for model weights. An
// identifier outside it must be expressed as a LicenseRef-* entry backed by
// reviewed licence text.
var pinnedSPDXLicenseIDs = map[string]struct{}{
	"0BSD": {}, "AFL-3.0": {}, "AGPL-3.0-only": {}, "AGPL-3.0-or-later": {}, "Apache-2.0": {},
	"Artistic-2.0": {}, "BSD-2-Clause": {}, "BSD-3-Clause": {}, "BSL-1.0": {}, "CC-BY-3.0": {},
	"CC-BY-4.0": {}, "CC-BY-NC-4.0": {}, "CC-BY-NC-SA-4.0": {}, "CC-BY-SA-3.0": {}, "CC-BY-SA-4.0": {},
	"CC0-1.0": {}, "CDLA-Permissive-2.0": {}, "ECL-2.0": {}, "EPL-2.0": {}, "EUPL-1.2": {},
	"GPL-2.0-only": {}, "GPL-2.0-or-later": {}, "GPL-3.0-only": {}, "GPL-3.0-or-later": {}, "ISC": {},
	"LGPL-2.1-only": {}, "LGPL-2.1-or-later": {}, "LGPL-3.0-only": {}, "LGPL-3.0-or-later": {}, "MIT": {},
	"MIT-0": {}, "MPL-2.0": {}, "NCSA": {}, "OpenRAIL": {}, "OSL-3.0": {}, "PostgreSQL": {},
	"Unlicense": {}, "UPL-1.0": {}, "Zlib": {},
}

var (
	errExtensionBody          = errors.New("poolmanifest: extension body is not the canonical encoding")
	errExtensionEmptyList     = errors.New("poolmanifest: an empty pool extension list must be omitted, not encoded")
	errModelEntriesBound      = errors.New("poolmanifest: pool_model_entries exceeds 256 entries")
	errModelEntriesOrder      = errors.New("poolmanifest: pool_model_entries must be strictly ascending by pool_model_id with no duplicates")
	errModelEntryID           = errors.New("poolmanifest: pool_model_id does not match pool/<pool_id>/<slug>")
	errModelEntryPoolID       = errors.New("poolmanifest: pool_model_id pool segment does not equal the core pool_id")
	errModelEntryAlgorithm    = errors.New("poolmanifest: artifact_hash_algorithm is outside the closed vocabulary")
	errModelEntryHash         = errors.New("poolmanifest: artifact_hash must be 64 lowercase hex characters")
	errModelEntryDupHash      = errors.New("poolmanifest: duplicate artifact_hash across pool_model_entries")
	errModelEntryRuntimes     = errors.New("poolmanifest: allowed_runtime_sources must be non-empty, ascending, duplicate-free, and allowed by the core")
	errModelEntryPairing      = errors.New("poolmanifest: allowed_runtime_sources pairs a runtime with an incompatible artifact format")
	errModelEntryLicense      = errors.New("poolmanifest: license is not a pinned SPDX identifier or LicenseRef-*")
	errModelEntryPaidServing  = errors.New("poolmanifest: paid_serving_attested must be true")
	errModelEntryDisclosure   = errors.New("poolmanifest: disclosure_class must be pool_attested_unverified")
	errModelEntryContext      = errors.New("poolmanifest: max_context_tokens must be in [1, 1048576]")
	errModelEntryPriceRange   = errors.New("poolmanifest: model entry rates must be int64 >= 0 with cache-hit <= prompt")
	errModelEntriesObserve    = errors.New("poolmanifest: pool_model_entries requires settlement mode enforce")
	errAttestedMembersBound   = errors.New("poolmanifest: pool_attested_members exceeds 1024 entries")
	errAttestedMembersOrder   = errors.New("poolmanifest: pool_attested_members must be strictly ascending by provider_account_id with no duplicates")
	errAttestedMemberAccount  = errors.New("poolmanifest: provider_account_id is not a canonical owner-account id")
	errAttestedMemberRuntimes = errors.New("poolmanifest: attested member runtime_classes must be non-empty, ascending, duplicate-free, and inside runtime_allowlist")
	// ErrPoolModelPricingBounds rejects an entry rate outside, or without,
	// the coordinator's configured pool-model pricing bounds (SPEC-005-R015).
	ErrPoolModelPricingBounds = errors.New("poolmanifest: model entry pricing is outside the configured pool_model_pricing_bounds")
	// ErrPoolModelShadowsCatalog rejects a pool_model_id that equals,
	// normalizes onto, or shadows a SPEC-010 canonical id.
	ErrPoolModelShadowsCatalog = errors.New("poolmanifest: pool_model_id shadows a SPEC-010 canonical catalog id")
	// ErrPoolModelCatalogOverlap rejects an entry whose exact artifact pair is
	// catalog-priceable for a runtime it lists, or blocked: the catalog wins.
	ErrPoolModelCatalogOverlap = errors.New("poolmanifest: pool model entry artifact resolves to a global catalog identity")
	// ErrPoolModelPricingBoundsUnset rejects every core carrying entries
	// while the coordinator has no valid configured pricing bounds.
	ErrPoolModelPricingBoundsUnset = fmt.Errorf("%w: bounds are unset or invalid", ErrPoolModelPricingBounds)
)

// Closed manifest-acceptance rejection codes for R015/R016 extension
// failures (SPEC-042-R010 manifest acceptance table, #1816 F4).
const (
	RejectCodePricingOutOfBounds = "pool_model_pricing_out_of_bounds"
	RejectCodePricingBoundsUnset = "pool_model_pricing_bounds_unset"
	RejectCodeShadowsCatalog     = "pool_model_id_shadows_catalog"
	RejectCodeCatalogOverlap     = "pool_model_entry_catalog_overlap"
	RejectCodeRuntimePairing     = "pool_model_entry_runtime_pairing"
	RejectCodeRuntimeNotAllowed  = "pool_model_entry_runtime_not_allowed"
	RejectCodeLicense            = "pool_model_entry_license_invalid"
	RejectCodePaidServing        = "pool_model_entry_paid_serving_unattested"
	RejectCodeDuplicate          = "pool_model_entry_duplicate"
	RejectCodeLimitExceeded      = "pool_model_entry_limit_exceeded"
	RejectCodeInvalid            = "pool_model_entry_invalid"
)

// PoolModelRejectCode classifies an error from R015/R016 extension
// validation or online acceptance into its closed rejection code. It returns
// "" for any other error.
func PoolModelRejectCode(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, ErrPoolModelPricingBoundsUnset):
		return RejectCodePricingBoundsUnset
	case errors.Is(err, ErrPoolModelPricingBounds):
		return RejectCodePricingOutOfBounds
	case errors.Is(err, ErrPoolModelShadowsCatalog):
		return RejectCodeShadowsCatalog
	case errors.Is(err, ErrPoolModelCatalogOverlap):
		return RejectCodeCatalogOverlap
	case errors.Is(err, errModelEntryPairing):
		return RejectCodeRuntimePairing
	case errors.Is(err, errModelEntryRuntimes), errors.Is(err, errAttestedMemberRuntimes):
		return RejectCodeRuntimeNotAllowed
	case errors.Is(err, errModelEntryLicense):
		return RejectCodeLicense
	case errors.Is(err, errModelEntryPaidServing):
		return RejectCodePaidServing
	case errors.Is(err, errModelEntryDupHash), errors.Is(err, errModelEntriesOrder), errors.Is(err, errAttestedMembersOrder):
		return RejectCodeDuplicate
	case errors.Is(err, errModelEntriesBound), errors.Is(err, errAttestedMembersBound):
		return RejectCodeLimitExceeded
	}
	for _, invalid := range []error{
		errExtensionBody, errExtensionEmptyList, errModelEntryID, errModelEntryPoolID, errModelEntryAlgorithm,
		errModelEntryHash, errModelEntryDisclosure, errModelEntryContext, errModelEntryPriceRange,
		errModelEntriesObserve, errAttestedMemberAccount,
	} {
		if errors.Is(err, invalid) {
			return RejectCodeInvalid
		}
	}
	return ""
}

// PoolModelPricing is an entry's trusted price in the SPEC-005 formula's
// three rates (credits per million tokens).
type PoolModelPricing struct {
	PromptRatePerMtok         uint64
	PromptCacheHitRatePerMtok uint64
	CompletionRatePerMtok     uint64
}

// PoolModelEntry is one SPEC-042-R015 model entry, encoded in this field order.
type PoolModelEntry struct {
	PoolModelID           string
	ArtifactHashAlgorithm string
	ArtifactHash          string
	AllowedRuntimeSources []string
	License               string
	PaidServingAttested   bool
	Pricing               PoolModelPricing
	DisclosureClass       string
	MaxContextTokens      uint64
}

// AllowsRuntimeSource reports whether the entry names runtimeSource.
func (m PoolModelEntry) AllowsRuntimeSource(runtimeSource string) bool {
	return runtimeSource != "" && containsString(m.AllowedRuntimeSources, runtimeSource)
}

// Equal reports whether two entries are field-for-field identical.
func (m PoolModelEntry) Equal(o PoolModelEntry) bool {
	return m.PoolModelID == o.PoolModelID && m.ArtifactHashAlgorithm == o.ArtifactHashAlgorithm &&
		m.ArtifactHash == o.ArtifactHash && stringsEqual(m.AllowedRuntimeSources, o.AllowedRuntimeSources) &&
		m.License == o.License && m.PaidServingAttested == o.PaidServingAttested && m.Pricing == o.Pricing &&
		m.DisclosureClass == o.DisclosureClass && m.MaxContextTokens == o.MaxContextTokens
}

// AttestedMember is one SPEC-042-R016 member-account attestation.
type AttestedMember struct {
	ProviderAccountID string
	RuntimeClasses    []string
}

// PoolModelPricingBounds are the coordinator's inclusive per-rate floors and
// ceilings for pool-model entries (SPEC-005-R015).
type PoolModelPricingBounds struct {
	MinPromptRatePerMtok         int64
	MaxPromptRatePerMtok         int64
	MinPromptCacheHitRatePerMtok int64
	MaxPromptCacheHitRatePerMtok int64
	MinCompletionRatePerMtok     int64
	MaxCompletionRatePerMtok     int64
}

// Validate rejects negative or inverted bounds.
func (b PoolModelPricingBounds) Validate() error {
	if b.MinPromptRatePerMtok < 0 || b.MinPromptCacheHitRatePerMtok < 0 || b.MinCompletionRatePerMtok < 0 ||
		b.MinPromptRatePerMtok > b.MaxPromptRatePerMtok ||
		b.MinPromptCacheHitRatePerMtok > b.MaxPromptCacheHitRatePerMtok ||
		b.MinCompletionRatePerMtok > b.MaxCompletionRatePerMtok {
		return ErrPoolModelPricingBounds
	}
	return nil
}

// poolModelPricingBoundsTag domain-separates the bounds digest a pool route
// snapshot records (SPEC-005-R015).
const poolModelPricingBoundsTag = "macprovider/spec005/pool-model-pricing-bounds/v1"

// SHA256Hex is the lowercase-hex digest of the bounds' canonical encoding
// (the domain tag, then the six signed 64-bit values big-endian in field
// order), recorded on every pool_manifest route snapshot.
func (b PoolModelPricingBounds) SHA256Hex() string {
	e := &encoder{}
	e.tag(poolModelPricingBoundsTag)
	for _, v := range []int64{b.MinPromptRatePerMtok, b.MaxPromptRatePerMtok, b.MinPromptCacheHitRatePerMtok,
		b.MaxPromptCacheHitRatePerMtok, b.MinCompletionRatePerMtok, b.MaxCompletionRatePerMtok} {
		e.u64(uint64(v))
	}
	sum := sha256.Sum256(e.buf)
	return hex.EncodeToString(sum[:])
}

// Contains reports whether every entry rate sits inside the inclusive bounds.
func (b PoolModelPricingBounds) Contains(p PoolModelPricing) bool {
	in := func(v uint64, lo, hi int64) bool { return v <= math.MaxInt64 && int64(v) >= lo && int64(v) <= hi }
	return b.Validate() == nil &&
		in(p.PromptRatePerMtok, b.MinPromptRatePerMtok, b.MaxPromptRatePerMtok) &&
		in(p.PromptCacheHitRatePerMtok, b.MinPromptCacheHitRatePerMtok, b.MaxPromptCacheHitRatePerMtok) &&
		in(p.CompletionRatePerMtok, b.MinCompletionRatePerMtok, b.MaxCompletionRatePerMtok)
}

// Violation names the first bound an entry's rates fall outside, with that
// bound's configured value: ok=false when the bounds contain the pricing.
// Bound names are the SPEC-005-R015 config keys (min_/max_ prompt,
// prompt_cache_hit, completion _rate_per_mtok).
func (b PoolModelPricingBounds) Violation(p PoolModelPricing) (bound string, limit int64, ok bool) {
	for _, r := range []struct {
		name   string
		v      uint64
		lo, hi int64
	}{
		{"prompt_rate_per_mtok", p.PromptRatePerMtok, b.MinPromptRatePerMtok, b.MaxPromptRatePerMtok},
		{"prompt_cache_hit_rate_per_mtok", p.PromptCacheHitRatePerMtok, b.MinPromptCacheHitRatePerMtok, b.MaxPromptCacheHitRatePerMtok},
		{"completion_rate_per_mtok", p.CompletionRatePerMtok, b.MinCompletionRatePerMtok, b.MaxCompletionRatePerMtok},
	} {
		if r.v > math.MaxInt64 || int64(r.v) > r.hi {
			return "max_" + r.name, r.hi, true
		}
		if int64(r.v) < r.lo {
			return "min_" + r.name, r.lo, true
		}
	}
	return "", 0, false
}

// PoolModelPricingBoundsError names the entry and the bound it violated; it
// is ErrPoolModelPricingBounds under errors.Is.
type PoolModelPricingBoundsError struct {
	PoolModelID string
	Bound       string
	Limit       int64
}

func (e *PoolModelPricingBoundsError) Error() string {
	return fmt.Sprintf("%v: %s violates %s=%d", ErrPoolModelPricingBounds, e.PoolModelID, e.Bound, e.Limit)
}

func (e *PoolModelPricingBoundsError) Unwrap() error { return ErrPoolModelPricingBounds }

// PoolModelEntries decodes the core's pool_model_entries/v1 extension. A core
// without it has no entries. The body must already be canonical (acceptance
// guarantees it for every accepted core).
func (pc PolicyCore) PoolModelEntries() ([]PoolModelEntry, error) {
	body, ok := pc.extensionBody(ExtensionPoolModelEntriesV1)
	if !ok {
		return nil, nil
	}
	return DecodePoolModelEntries(body)
}

// PoolAttestedMembers decodes the core's pool_attested_members/v1 extension.
func (pc PolicyCore) PoolAttestedMembers() ([]AttestedMember, error) {
	body, ok := pc.extensionBody(ExtensionPoolAttestedMembersV1)
	if !ok {
		return nil, nil
	}
	return DecodeAttestedMembers(body)
}

func (pc PolicyCore) extensionBody(id string) ([]byte, bool) {
	if !pc.IsV2() {
		return nil, false
	}
	for _, ext := range pc.Extensions {
		if ext.ID == id {
			return ext.Body, true
		}
	}
	return nil, false
}

// SetPoolExtensions replaces the core's pool extensions with the canonical
// encodings of entries and members (each omitted when empty) and keeps the
// extension list strictly ascending. The core must use the v2 encoding.
func (pc *PolicyCore) SetPoolExtensions(entries []PoolModelEntry, members []AttestedMember) error {
	if !pc.IsV2() {
		return errV1CarriesV2Fields
	}
	kept := pc.Extensions[:0:0]
	for _, ext := range pc.Extensions {
		if ext.ID != ExtensionPoolModelEntriesV1 && ext.ID != ExtensionPoolAttestedMembersV1 {
			kept = append(kept, ext)
		}
	}
	if len(entries) > 0 {
		body, err := EncodePoolModelEntries(entries)
		if err != nil {
			return err
		}
		kept = append(kept, PolicyExtension{ID: ExtensionPoolModelEntriesV1, Body: body})
	}
	if len(members) > 0 {
		body, err := EncodeAttestedMembers(members)
		if err != nil {
			return err
		}
		kept = append(kept, PolicyExtension{ID: ExtensionPoolAttestedMembersV1, Body: body})
	}
	sort.SliceStable(kept, func(i, j int) bool { return kept[i].ID < kept[j].ID })
	pc.Extensions = kept
	return nil
}

// EncodePoolModelEntries is the canonical pool_model_entries/v1 body:
// u32 count, then each entry's fields in R015 order.
func EncodePoolModelEntries(entries []PoolModelEntry) ([]byte, error) {
	if len(entries) == 0 {
		return nil, errExtensionEmptyList
	}
	if len(entries) > MaxPoolModelEntries {
		return nil, errModelEntriesBound
	}
	e := &encoder{}
	e.u32count(len(entries))
	for _, m := range entries {
		e.str(m.PoolModelID)
		e.str(m.ArtifactHashAlgorithm)
		e.str(m.ArtifactHash)
		e.u32count(len(m.AllowedRuntimeSources))
		for _, source := range m.AllowedRuntimeSources {
			e.str(source)
		}
		e.str(m.License)
		e.boolean(m.PaidServingAttested)
		e.u64(m.Pricing.PromptRatePerMtok)
		e.u64(m.Pricing.PromptCacheHitRatePerMtok)
		e.u64(m.Pricing.CompletionRatePerMtok)
		e.str(m.DisclosureClass)
		e.u64(m.MaxContextTokens)
	}
	if e.err != nil {
		return nil, e.err
	}
	return e.buf, nil
}

// DecodePoolModelEntries is the strict inverse of EncodePoolModelEntries: a
// truncated, trailing, or non-canonical body fails.
func DecodePoolModelEntries(body []byte) ([]PoolModelEntry, error) {
	d := &decoder{buf: body}
	n := d.count()
	if d.err == nil && n > MaxPoolModelEntries {
		return nil, errModelEntriesBound
	}
	var out []PoolModelEntry
	for i := 0; i < n && d.err == nil; i++ {
		var m PoolModelEntry
		m.PoolModelID = d.str()
		m.ArtifactHashAlgorithm = d.str()
		m.ArtifactHash = d.str()
		for k, j := d.count(), 0; j < k && d.err == nil; j++ {
			m.AllowedRuntimeSources = append(m.AllowedRuntimeSources, d.str())
		}
		m.License = d.str()
		m.PaidServingAttested = d.boolean()
		m.Pricing.PromptRatePerMtok = d.u64()
		m.Pricing.PromptCacheHitRatePerMtok = d.u64()
		m.Pricing.CompletionRatePerMtok = d.u64()
		m.DisclosureClass = d.str()
		m.MaxContextTokens = d.u64()
		out = append(out, m)
	}
	if err := d.done(); err != nil {
		return nil, errExtensionBody
	}
	if len(out) == 0 {
		return nil, errExtensionEmptyList
	}
	if again, err := EncodePoolModelEntries(out); err != nil || !bytes.Equal(again, body) {
		return nil, errExtensionBody
	}
	return out, nil
}

// EncodeAttestedMembers is the canonical pool_attested_members/v1 body.
func EncodeAttestedMembers(members []AttestedMember) ([]byte, error) {
	if len(members) == 0 {
		return nil, errExtensionEmptyList
	}
	if len(members) > MaxAttestedMembers {
		return nil, errAttestedMembersBound
	}
	e := &encoder{}
	e.u32count(len(members))
	for _, a := range members {
		e.str(a.ProviderAccountID)
		e.u32count(len(a.RuntimeClasses))
		for _, source := range a.RuntimeClasses {
			e.str(source)
		}
	}
	if e.err != nil {
		return nil, e.err
	}
	return e.buf, nil
}

// DecodeAttestedMembers is the strict inverse of EncodeAttestedMembers.
func DecodeAttestedMembers(body []byte) ([]AttestedMember, error) {
	d := &decoder{buf: body}
	n := d.count()
	if d.err == nil && n > MaxAttestedMembers {
		return nil, errAttestedMembersBound
	}
	var out []AttestedMember
	for i := 0; i < n && d.err == nil; i++ {
		var a AttestedMember
		a.ProviderAccountID = d.str()
		for k, j := d.count(), 0; j < k && d.err == nil; j++ {
			a.RuntimeClasses = append(a.RuntimeClasses, d.str())
		}
		out = append(out, a)
	}
	if err := d.done(); err != nil {
		return nil, errExtensionBody
	}
	if len(out) == 0 {
		return nil, errExtensionEmptyList
	}
	if again, err := EncodeAttestedMembers(out); err != nil || !bytes.Equal(again, body) {
		return nil, errExtensionBody
	}
	return out, nil
}

// validatePoolExtensions applies the closed R015/R016 rules to an accepted
// v2 core's pool extensions. It never consults the catalog or the pricing
// bounds; ValidatePoolModelAcceptance applies those at online acceptance.
func (pc PolicyCore) validatePoolExtensions() error {
	entries, err := pc.PoolModelEntries()
	if err != nil {
		return err
	}
	if len(entries) > 0 && pc.SettlementMode != "enforce" {
		return errModelEntriesObserve
	}
	seenHash := make(map[string]struct{}, len(entries))
	for i, m := range entries {
		if i > 0 && m.PoolModelID <= entries[i-1].PoolModelID {
			return errModelEntriesOrder
		}
		poolID, _, ok := ParsePoolModelID(m.PoolModelID)
		if !ok {
			return errModelEntryID
		}
		if poolID != pc.PoolID {
			return errModelEntryPoolID
		}
		format := m.ArtifactHashAlgorithm
		if format != ArtifactHashAlgorithmGGUFFileV1 && format != ArtifactHashAlgorithmSnapshotManifestV1 {
			return errModelEntryAlgorithm
		}
		if !artifactHashPattern.MatchString(m.ArtifactHash) {
			return errModelEntryHash
		}
		if _, dup := seenHash[m.ArtifactHash]; dup {
			return errModelEntryDupHash
		}
		seenHash[m.ArtifactHash] = struct{}{}
		if len(m.AllowedRuntimeSources) == 0 || !strictlyAscending(m.AllowedRuntimeSources) {
			return errModelEntryRuntimes
		}
		for _, source := range m.AllowedRuntimeSources {
			if source != RuntimeSourceNativeMLX && !containsString(pc.RuntimeAllowlist, source) {
				return errModelEntryRuntimes
			}
			if want, ok := RuntimeSourceFormat(source); !ok || want != format {
				return errModelEntryPairing
			}
		}
		if !validPoolModelLicense(m.License) {
			return errModelEntryLicense
		}
		if !m.PaidServingAttested {
			return errModelEntryPaidServing
		}
		if m.Pricing.PromptRatePerMtok > math.MaxInt64 || m.Pricing.CompletionRatePerMtok > math.MaxInt64 ||
			m.Pricing.PromptCacheHitRatePerMtok > m.Pricing.PromptRatePerMtok {
			return errModelEntryPriceRange
		}
		if m.DisclosureClass != PoolModelDisclosureClass {
			return errModelEntryDisclosure
		}
		if m.MaxContextTokens < 1 || m.MaxContextTokens > MaxPoolModelContext {
			return errModelEntryContext
		}
	}
	members, err := pc.PoolAttestedMembers()
	if err != nil {
		return err
	}
	for i, a := range members {
		if i > 0 && a.ProviderAccountID <= members[i-1].ProviderAccountID {
			return errAttestedMembersOrder
		}
		if len(a.ProviderAccountID) > maxProviderAccountBytes || !providerAccountPattern.MatchString(a.ProviderAccountID) {
			return errAttestedMemberAccount
		}
		if len(a.RuntimeClasses) == 0 || !strictlyAscending(a.RuntimeClasses) {
			return errAttestedMemberRuntimes
		}
		for _, source := range a.RuntimeClasses {
			if !containsString(pc.RuntimeAllowlist, source) {
				return errAttestedMemberRuntimes
			}
		}
	}
	return nil
}

// PoolModelAcceptanceContext is the coordinator state R015 entries are
// checked against at online manifest acceptance.
type PoolModelAcceptanceContext struct {
	// PricingBounds are the configured pool-model bounds; nil fails every
	// entry closed (SPEC-005-R015).
	PricingBounds *PoolModelPricingBounds
	// IsCatalogModelID reports whether id equals or normalizes onto a
	// SPEC-010 canonical id.
	IsCatalogModelID func(id string) bool
	// ArtifactInCatalog reports whether an exact artifact pair is
	// catalog-priceable for any of runtimes (a recommendable row with a
	// verified member usable by that class) or resolves to a blocked row
	// (SPEC-042-R015 catalog overlap and precedence).
	ArtifactInCatalog func(algorithm, hash string, runtimes []string) bool
}

// ValidatePoolModelAcceptance applies the context-dependent R015 rules: every
// entry rate inside the configured bounds, no pool_model_id shadowing a
// catalog id (the full id, its lowercase form, or its slug), and no artifact
// pair that is catalog-priceable for a listed runtime or blocked. A core without entries
// needs no context; a core with entries and missing context fails closed.
func (pc PolicyCore) ValidatePoolModelAcceptance(ctx PoolModelAcceptanceContext) error {
	entries, err := pc.PoolModelEntries()
	if err != nil {
		return err
	}
	if len(entries) == 0 {
		return nil
	}
	if ctx.PricingBounds == nil || ctx.PricingBounds.Validate() != nil {
		return ErrPoolModelPricingBoundsUnset
	}
	if ctx.IsCatalogModelID == nil {
		return ErrPoolModelShadowsCatalog
	}
	if ctx.ArtifactInCatalog == nil {
		return ErrPoolModelCatalogOverlap
	}
	for _, m := range entries {
		if !ctx.PricingBounds.Contains(m.Pricing) {
			if bound, limit, ok := ctx.PricingBounds.Violation(m.Pricing); ok {
				return &PoolModelPricingBoundsError{PoolModelID: m.PoolModelID, Bound: bound, Limit: limit}
			}
			return ErrPoolModelPricingBounds
		}
		slug := m.PoolModelID[strings.LastIndexByte(m.PoolModelID, '/')+1:]
		for _, candidate := range []string{m.PoolModelID, strings.ToLower(m.PoolModelID), slug} {
			if ctx.IsCatalogModelID(candidate) {
				return ErrPoolModelShadowsCatalog
			}
		}
		if ctx.ArtifactInCatalog(m.ArtifactHashAlgorithm, m.ArtifactHash, m.AllowedRuntimeSources) {
			return ErrPoolModelCatalogOverlap
		}
	}
	return nil
}

// ParsePoolModelID splits a grammatical pool_model_id into its pool id and slug.
func ParsePoolModelID(id string) (poolID, slug string, ok bool) {
	if len(id) > maxPoolModelIDBytes {
		return "", "", false
	}
	m := poolModelIDPattern.FindStringSubmatch(id)
	if m == nil {
		return "", "", false
	}
	return m[1], m[2], true
}

// IsPoolModelID reports whether id is in the reserved pool/ namespace.
func IsPoolModelID(id string) bool {
	return strings.HasPrefix(strings.ToLower(strings.TrimSpace(id)), "pool/")
}

// RuntimeSourceFormat is the artifact hash algorithm a runtime class serves
// under R015: GGUF for llama.cpp, LM Studio and Ollama; the MLX snapshot
// manifest for native MLX, mlx_lm.server and oMLX.
func RuntimeSourceFormat(runtimeSource string) (string, bool) {
	switch runtimeSource {
	case RuntimeSourceLlamacppLoopback, RuntimeSourceLMStudioLoopback, RuntimeSourceOllamaLoopback:
		return ArtifactHashAlgorithmGGUFFileV1, true
	case RuntimeSourceNativeMLX, RuntimeSourceMLXLMLoopback, RuntimeSourceOMLXLoopback:
		return ArtifactHashAlgorithmSnapshotManifestV1, true
	default:
		return "", false
	}
}

func validPoolModelLicense(license string) bool {
	if _, ok := pinnedSPDXLicenseIDs[license]; ok {
		return true
	}
	return licenseRefPattern.MatchString(license)
}

func strictlyAscending(xs []string) bool {
	for i := 1; i < len(xs); i++ {
		if xs[i] <= xs[i-1] {
			return false
		}
	}
	return true
}

func containsString(xs []string, v string) bool {
	for _, x := range xs {
		if x == v {
			return true
		}
	}
	return false
}

func stringsEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// ClonePoolModelEntries returns a deep copy.
func ClonePoolModelEntries(in []PoolModelEntry) []PoolModelEntry {
	if in == nil {
		return nil
	}
	out := make([]PoolModelEntry, len(in))
	for i, m := range in {
		out[i] = m
		out[i].AllowedRuntimeSources = append([]string(nil), m.AllowedRuntimeSources...)
	}
	return out
}

// CloneAttestedMembers returns a deep copy.
func CloneAttestedMembers(in []AttestedMember) []AttestedMember {
	if in == nil {
		return nil
	}
	out := make([]AttestedMember, len(in))
	for i, a := range in {
		out[i] = AttestedMember{ProviderAccountID: a.ProviderAccountID, RuntimeClasses: append([]string(nil), a.RuntimeClasses...)}
	}
	return out
}
