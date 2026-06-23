import OpenAI from "openai";

function baseURL(raw) {
  const trimmed = raw.replace(/\/+$/, "");
  return trimmed.endsWith("/v1") ? trimmed : `${trimmed}/v1`;
}

const endpoint = process.env.MACPROVIDER_SPEC015_GATEWAY_URL;
if (!endpoint) {
  console.error("MACPROVIDER_SPEC015_GATEWAY_URL is required");
  process.exit(2);
}

const model = process.env.MACPROVIDER_SPEC015_MODEL || "llama-3.2-3b-instruct";
const client = new OpenAI({
  apiKey: process.env.MACPROVIDER_SPEC015_API_KEY || "test-key",
  baseURL: baseURL(endpoint),
  timeout: 30000,
});

const nonStreaming = await client.chat.completions.create({
  model,
  messages: [{ role: "user", content: "SPEC-015 SDK non-streaming smoke" }],
  max_tokens: 16,
});
if (!nonStreaming.choices?.[0]?.message?.content) {
  throw new Error("non-streaming returned empty content");
}

const stream = await client.chat.completions.create({
  model,
  messages: [{ role: "user", content: "SPEC-015 SDK streaming smoke" }],
  max_tokens: 16,
  stream: true,
});
let sawStreamChunk = false;
for await (const chunk of stream) {
  if (chunk.choices?.length) {
    sawStreamChunk = true;
  }
}
if (!sawStreamChunk) {
  throw new Error("streaming returned no chunks");
}

console.log("openai-node SPEC-015 SDK compatibility smoke passed");
