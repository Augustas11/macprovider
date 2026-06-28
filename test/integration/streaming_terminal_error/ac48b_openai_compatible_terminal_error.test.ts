import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { afterEach, describe, expect, it } from "vitest";
import { streamText } from "ai";
import { createOpenAICompatible } from "@ai-sdk/openai-compatible";

const terminalErrorEvents = [
  {
    id: "chatcmpl-ac48b",
    object: "chat.completion.chunk",
    choices: [
      {
        index: 0,
        delta: {
          tool_calls: [
            {
              index: 0,
              id: "call_0123456789abcdef",
              type: "function",
              function: { name: "write_file", arguments: "{\"path\":\"README.md\"," },
            },
          ],
        },
        finish_reason: null,
      },
    ],
  },
  {
    id: "chatcmpl-ac48b",
    object: "chat.completion.chunk",
    choices: [
      {
        index: 0,
        delta: {
          tool_calls: [
            {
              index: 0,
              function: { arguments: "\"content\":\"partial" },
            },
          ],
        },
        finish_reason: null,
      },
    ],
  },
  {
    error: {
      message: "Provider closed before tool-call stream completed",
      type: "server_error",
      code: "tool_call_final_close_failed",
      param: null,
      retryable: true,
      request_id: "req-ac48b",
      inference_ran: true,
      settlement_ran: false,
    },
  },
];

let cleanup: (() => Promise<void>) | undefined;

afterEach(async () => {
  if (cleanup) {
    await cleanup();
    cleanup = undefined;
  }
});

function terminalErrorServer(): Promise<{ baseURL: string; close: () => Promise<void> }> {
  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    if (req.method !== "POST" || req.url !== "/v1/chat/completions") {
      res.statusCode = 404;
      res.end();
      return;
    }
    for await (const _ of req) {
      // drain request body
    }
    res.writeHead(200, {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache",
    });
    for (const event of terminalErrorEvents) {
      res.write(`data: ${JSON.stringify(event)}\n\n`);
    }
    res.write("data: [DONE]\n\n");
    res.end();
  });

  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (typeof address !== "object" || address === null) {
        reject(new Error("server did not bind a TCP port"));
        return;
      }
      resolve({
        baseURL: `http://127.0.0.1:${address.port}/v1`,
        close: () => new Promise<void>((done, fail) => server.close((err) => (err ? fail(err) : done()))),
      });
    });
  });
}

describe("AC-48b Cline OpenAI-compatible terminal error", () => {
  it("routes terminal-error SSE through Vercel AI SDK without yielding dispatchable tool calls", async () => {
    const server = await terminalErrorServer();
    cleanup = server.close;
    const provider = createOpenAICompatible({
      name: "macprovider-ac48b",
      baseURL: server.baseURL,
      apiKey: "test",
    });

    let sawToolCallPart = false;
    let sawSuccessfulText = false;
    let threw = false;
    try {
      const result = streamText({
        model: provider.chatModel("fixture-model"),
        prompt: "write README.md",
      });
      for await (const part of result.fullStream) {
        if (String(part.type).includes("tool-call")) {
          sawToolCallPart = true;
        }
        if (part.type === "text-delta" && part.text) {
          sawSuccessfulText = true;
        }
      }
    } catch {
      threw = true;
    }

    expect(sawToolCallPart).toBe(false);
    expect(sawSuccessfulText).toBe(false);
    expect(threw || (!sawToolCallPart && !sawSuccessfulText)).toBe(true);
  });
});
