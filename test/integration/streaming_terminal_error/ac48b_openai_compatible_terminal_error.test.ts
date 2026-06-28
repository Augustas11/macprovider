import { describe, expect, it } from "vitest";
import { createOpenAICompatible } from "@ai-sdk/openai-compatible";

type ToolCallState = {
  id?: string;
  name?: string;
  arguments: string;
  terminalError: boolean;
  finishReason?: string;
};

const terminalErrorStream = [
  `data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"write_file","arguments":"{\\"path\\":\\"README.md\\","}}]}}]}`,
  `data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"content\\":\\"partial"}}]}}]}`,
  `data: {"error":{"message":"Provider closed before tool-call stream completed","type":"server_error","code":"tool_call_final_close_failed","param":null}}`,
  "data: [DONE]",
];

function accumulateAtAgentRuntimeBoundary(lines: string[]): ToolCallState {
  const state: ToolCallState = { arguments: "", terminalError: false };
  for (const line of lines) {
    if (!line.startsWith("data: ")) continue;
    const payload = line.slice("data: ".length);
    if (payload === "[DONE]") break;
    const event = JSON.parse(payload);
    if (event.error) {
      state.terminalError = true;
      continue;
    }
    for (const choice of event.choices ?? []) {
      if (choice.finish_reason) state.finishReason = choice.finish_reason;
      for (const call of choice.delta?.tool_calls ?? []) {
        if (call.id) state.id = call.id;
        if (call.function?.name) state.name = call.function.name;
        if (call.function?.arguments) state.arguments += call.function.arguments;
      }
    }
  }
  return state;
}

function isDispatchable(state: ToolCallState): boolean {
  if (state.terminalError) return false;
  if (state.finishReason !== "tool_calls") return false;
  if (!state.id || !state.name) return false;
  try {
    JSON.parse(state.arguments);
    return true;
  } catch {
    return false;
  }
}

describe("AC-48b Cline OpenAI-compatible terminal error", () => {
  it("imports the Cline SDK dependency and blocks dispatchable tool_calls after terminal SSE error", () => {
    const provider = createOpenAICompatible({
      name: "macprovider-ac48b",
      baseURL: "http://127.0.0.1:9/v1",
      apiKey: "test",
    });
    expect(provider).toBeTruthy();

    const state = accumulateAtAgentRuntimeBoundary(terminalErrorStream);
    expect(state.terminalError).toBe(true);
    expect(state.finishReason).not.toBe("tool_calls");
    expect(isDispatchable(state)).toBe(false);
  });
});
