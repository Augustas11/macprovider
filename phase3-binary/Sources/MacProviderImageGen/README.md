# StableDiffusion source provenance

Vendored from MIT-licensed `ml-explore/mlx-swift-examples`, tag `2.29.1`,
`Libraries/StableDiffusion`. Copyright notices and the complete MIT licence
are preserved in this directory. The release notices generator includes it.

Adaptations: provider-owned verified local file resolution replaces Hub
snapshot fetching; only the SDXL-Turbo preset is exposed, with fp16 variant
filenames. The backend downloads the revision and SHA-256 identities listed
in `WeightManifest.swift`, streams to disk with URLSession resume support,
checks cancellation at denoise boundaries, and returns PNG data. A request's
random state is task scoped rather than mutating MLX's global random seed.
Prompts retain EOS within CLIP's 77 position embeddings, and SDXL size
conditioning follows the requested output dimensions.

The weights have their own Stability AI model licence; the MIT licence here
covers the runtime source, not the model weights. Model repository:
https://huggingface.co/stabilityai/sdxl-turbo
