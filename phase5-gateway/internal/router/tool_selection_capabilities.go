package router

// mergeToolChoiceModes mirrors the coordinator's schema-holdback-v1 contract
// (SPEC-018 §3.11): a native provider's declared modes for its exact loaded
// model. Grammar-mask family support is advertised by upgraded native providers; family
// recognition alone never grants a guaranteed mode to an older provider. A session must
// bind enforcement to its current model and runtime; stale swap data is ignored.
func mergeToolChoiceModes(current []string, provider poolzProviderRow) []string {
	supported := map[string]bool{"auto": true}
	for _, mode := range current {
		supported[mode] = true
	}
	for _, capability := range provider.ToolSelectionCapabilities {
		if capability.ModelID != provider.ModelID || capability.Runtime != "mlx_cache" ||
			(provider.RuntimeSource != "" && provider.RuntimeSource != "mlx_cache") ||
			capability.Validation != "schema-holdback-v1" {
			continue
		}
		for _, mode := range capability.Modes {
			if mode == "none" || mode == "required" || mode == "named" {
				supported[mode] = true
			}
		}
	}
	var modes []string
	for _, mode := range []string{"auto", "none", "required", "named"} {
		if supported[mode] {
			modes = append(modes, mode)
		}
	}
	return modes
}
