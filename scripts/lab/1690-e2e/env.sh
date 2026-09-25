# Sourced by the #1690 e2e scripts: the lab release inputs the M8 rig needs
# for all four engines (real MLX snapshot-manifest digest, mlx_cache +
# mlxlm_loopback on the MLX primary, the Ollama qwen2.5:0.5b blob).
export MLX_SHA=1bbee07a0dea46fa6d970fe2f3cebac9da287ba614d02d3319c945e886c0f4ea
export MLX_RUNTIME_SOURCES=mlx_cache,mlxlm_loopback
export OLLAMA_GGUF_SHA=c5396e06af294bd101b30dce59131a76d2b773e76950acc870eda801d3ab0515
export OLLAMA_GGUF_SIZE=397807936
