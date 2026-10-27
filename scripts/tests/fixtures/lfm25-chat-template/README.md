# LFM2.5 native chat-template fixture

`chat_template.jinja` is copied byte-for-byte from
`LiquidAI/LFM2.5-24B-A2B-MLX-4bit` at revision
`667408d494bde191c2cb9dd4f4549827816b9275`.

Source: https://huggingface.co/LiquidAI/LFM2.5-24B-A2B-MLX-4bit/blob/667408d494bde191c2cb9dd4f4549827816b9275/chat_template.jinja

SHA-256: `aadd425edb1d42fe9288e5de3624c21c1c03099129b9cfea5978f1bc67222c0a`.

The source model uses the Liquid AI LFM Open License (conditional commercial
terms); the full pinned `LICENSE` is retained alongside the template. This fixture preserves its upstream template for compatibility testing.
`LFMToolRuntimeTests` renders it through the production compatibility rewrite
and verifies native history, tool results, and ongoing-turn reasoning.
