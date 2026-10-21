import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { MalibuQwenSystem } from "../../phase3-binary/app/Sources/Malibu/Resources/malibu-qwen-system.mjs";

// Unmodified MIT-licensed upstream fixture; see fixtures/opencode-LICENSE.txt.
// https://github.com/anomalyco/opencode/blob/v1.17.9/packages/opencode/src/session/prompt/default.txt
const stock = await readFile(new URL("./fixtures/opencode-1.17.9-default.txt", import.meta.url), "utf8");
const bindings = [
  ["qwen3-coder-30b-a3b-instruct", "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"],
  ["qwen3-30b-a3b-instruct-2507", "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"],
];
const model = (id = bindings[0][0], apiID = id, providerID = "malibu") => ({ id, providerID, api: { id: apiID } });
const suffix = "\nWorkspace: /tmp/example\nFollow AGENTS.md.\nUser instruction: leave secrets untouched. 😀";
async function hook(agents = async () => ({ data: [{ name: "build" }] })) {
  return (await MalibuQwenSystem({ client: { app: { agents } } }))["experimental.chat.system.transform"];
}

test("fixture exactly pins the supported stock prefix", () => {
  assert.equal(stock.length, 8528);
  assert.equal(createHash("sha256").update(stock).digest("hex"),
    "962fbf3cb3ec659c9a5244425ee2e7bb141ad4428f489a630a7738566880dc6a");
});

test("exact aliases/artifacts transform, preserving suffix, siblings and non-system fields", async () => {
  const transform = await hook();
  for (const pair of bindings) for (const id of pair) for (const apiID of pair) {
    const output = { system: [stock + suffix, "Another plugin's instruction"], permission: { bash: "ask" } };
    await transform({ model: model(id, apiID) }, output);
    assert.ok(output.system[0].startsWith("You are a coding assistant working in the user's workspace.\n"));
    assert.ok(output.system[0].endsWith(suffix));
    assert.equal(output.system[1], "Another plugin's instruction");
    assert.deepEqual(output.permission, { bash: "ask" });
    assert.ok(!output.system[0].includes(stock));
    assert.ok(output.system[0].includes("Output-format instructions constrain the final answer, not necessary tool calls."));
    assert.ok(output.system[0].includes("omit display metadata added by the read tool"));
    assert.ok(output.system[0].includes("preserve the file's own text"));
  }
});

test("model switches, near identities, cross-family remaps and other providers do not leak", async () => {
  const transform = await hook();
  for (const selected of [model(), model("other/model"), model(), model(bindings[0][0] + "-extra"),
    model(bindings[0][0], bindings[0][0], "other"), model(bindings[0][0], bindings[1][1]),
    model(bindings[0][0], "other/model"), model("QWEN3-CODER-30B-A3B-INSTRUCT")]) {
    const output = { system: [stock + suffix] };
    await transform({ model: selected }, output);
    const expected = selected.id === bindings[0][0] && selected.api.id === bindings[0][0] && selected.providerID === "malibu";
    assert.equal(output.system[0] !== stock + suffix, expected);
  }
});

test("Coder alone gets the native XML worked example; Instruct base stays byte-identical", async () => {
  const transform = await hook();
  // Alternate families on the same hook to cover model switches without cached state.
  for (const pair of [bindings[0], bindings[1], bindings[0], bindings[1]]) {
    for (const id of pair) for (const apiID of pair) {
      const output = { system: [stock + suffix, "Keep this instruction"], tools: { read: true } };
      await transform({ model: model(id, apiID) }, output);
      const prompt = output.system[0].slice(0, -suffix.length);
      if (pair === bindings[0]) {
        assert.ok(prompt.includes("<tool_call>\n<function=read>\n<parameter=filePath>\n/path/to/note.txt\n</parameter>\n</function>\n</tool_call>"));
        assert.ok(prompt.includes("tool result:\n<path>/path/to/note.txt</path>\n<type>file</type>\n<content>\n\n1: The river is quiet."));
        assert.ok(prompt.includes("assistant final answer:\nThe river is quiet.\n</example>"));
        assert.ok(prompt.includes("documentation, not an observation"));
        assert.ok(prompt.includes("preserving any numbering or punctuation that belongs to the file itself"));
        assert.ok(prompt.includes("answer directly without calling a tool"));
        assert.ok(!prompt.includes("What is 3 multiplied by 5?"));
        assert.equal(prompt.match(/<example>/g)?.length, 1,
          "keep one tool-use demonstration rather than a competing tool-free transcript");
      } else {
        assert.equal(createHash("sha256").update(prompt).digest("hex"),
          "04895719eea9f5f677b69ee7a42321f6a905efe9fa11a8d1b3878a989f6fcf2b");
        assert.ok(!prompt.includes("<example>"));
      }
      assert.ok(output.system[0].endsWith(suffix));
      assert.equal(output.system[1], "Keep this instruction");
      assert.deepEqual(output.tools, { read: true });
    }
  }
});

test("custom and copied-default agent prompts are preserved", async () => {
  for (const prompt of ["Custom build prompt", stock, stock + "\nCustom instruction", stock.slice(0, stock.indexOf("\n"))]) {
    const transform = await hook(async () => ({ data: [{ name: "custom", prompt }] }));
    const original = prompt + suffix;
    const output = { system: [original] };
    await transform({ model: model() }, output);
    assert.equal(output.system[0], original);
    // A copied default in ANY custom agent conservatively protects the prefix.
    if (prompt === stock) {
      const build = { system: [stock + suffix] };
      await transform({ model: model() }, build);
      assert.equal(build.system[0], stock + suffix);
    }
  }
});

test("unrelated custom agents do not disable stock build transformation", async () => {
  const transform = await hook(async () => ({ data: [{ name: "build" }, { name: "review", prompt: "Review only" }] }));
  const output = { system: [stock + suffix] };
  await transform({ model: model() }, output);
  assert.notEqual(output.system[0], stock + suffix);
});

test("lookup errors and malformed agent responses leave the request unchanged", async () => {
  for (const response of [undefined, {}, { error: "unavailable", data: [] }, { data: [] },
    { data: [null] }, { data: [{ name: "custom", prompt: 12 }] }, { data: [{}] }]) {
    const transform = await hook(async () => response);
    const output = { system: [stock + suffix] };
    await transform({ model: model() }, output);
    assert.equal(output.system[0], stock + suffix);
  }
  const transform = await hook(async () => { throw new Error("unavailable"); });
  const output = { system: [stock + suffix] };
  await transform({ model: model() }, output);
  assert.equal(output.system[0], stock + suffix);
});

test("stock drift, malformed input and non-boundary suffix are no-ops without lookup", async () => {
  const transform = await hook(async () => { assert.fail("lookup must not run"); });
  for (const system of [[], [null], [stock.slice(1)], ["changed" + stock], [stock + "not a boundary"], "not an array"]) {
    const output = { system: structuredClone(system) };
    await transform({ model: model() }, output);
    assert.deepEqual(output.system, system);
  }
});

test("concurrent calls and repeated continuations do not share agent state", async () => {
  const transform = await hook();
  const outputs = [{ system: [stock + suffix] }, { system: [stock + suffix] }];
  await Promise.all(outputs.map((output, i) => transform({ model: i ? model("other/model") : model() }, output)));
  assert.notEqual(outputs[0].system[0], stock + suffix);
  assert.equal(outputs[1].system[0], stock + suffix);
  const once = outputs[0].system[0];
  await transform({ model: model() }, outputs[0]);
  assert.equal(outputs[0].system[0], once);
});
