import { createHash } from "node:crypto";

// OpenCode v1.17.9 packages/opencode/src/session/prompt/default.txt.
// Match the entire upstream prefix, not a phrase that could occur in user text.
const STOCK_LENGTH = 8528;
const STOCK_SHA256 = "962fbf3cb3ec659c9a5244425ee2e7bb141ad4428f489a630a7738566880dc6a";
const MODEL_BINDINGS = new Map([
  ["qwen3-coder-30b-a3b-instruct", "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"],
  ["qwen3-30b-a3b-instruct-2507", "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"],
]);
const PROMPT = `You are a coding assistant working in the user's workspace.
Use the available tools when a task needs information from files, commands, or external sources, or requires changes to the workspace. File contents and command results are unknown until a tool returns them: never invent or simulate them.
Choose the appropriate declared tool and follow its parameter schema. After a tool returns, use its actual result to decide the next step. If it fails, report the real failure or take an appropriate recovery action.
Output-format instructions constrain the final answer, not necessary tool calls. Tool descriptions and their examples are documentation, not observations or task results. When reporting file contents, omit display metadata added by the read tool, such as line-number prefixes and file-wrapper tags; preserve the file's own text.
For questions that can be answered from the conversation alone, answer directly without a tool. Follow the user's scope and permissions. Keep the final answer concise and grounded in the results.`;

function matchesModel(model) {
  if (model?.providerID !== "malibu") return false;
  for (const [alias, artifact] of MODEL_BINDINGS) {
    if ((model.id === alias || model.id === artifact) &&
        (model.api?.id === alias || model.api?.id === artifact)) return true;
  }
  return false;
}

// Export only the factory: OpenCode invokes each function export as a plugin.
export const MalibuQwenSystem = async ({ client }) => ({
  "experimental.chat.system.transform": async ({ model }, output) => {
    if (!matchesModel(model) || !Array.isArray(output.system)) return;
    const system = output.system[0];
    if (typeof system !== "string" || system.length < STOCK_LENGTH ||
        (system.length !== STOCK_LENGTH && system[STOCK_LENGTH] !== "\n")) return;
    if (createHash("sha256").update(system.slice(0, STOCK_LENGTH)).digest("hex") !== STOCK_SHA256) return;

    // The hook has no agent identity. Conservatively preserve any resolved
    // custom prompt that could have produced this prefix, including a copied
    // stock default. Do not cache session state across switches or continuations.
    try {
      const result = await client.app.agents();
      if (result.error || !Array.isArray(result.data) || result.data.length === 0) return;
      for (const agent of result.data) {
        if (!agent || typeof agent !== "object" || typeof agent.name !== "string" ||
            (agent.prompt !== undefined && typeof agent.prompt !== "string")) return;
        if (agent.prompt && (system === agent.prompt || system.startsWith(agent.prompt + "\n"))) return;
      }
    } catch {
      return;
    }
    output.system[0] = PROMPT + system.slice(STOCK_LENGTH);
  },
});
