import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const signerPath = new URL("../../Sources/Malibu/Resources/payout-signer/signer.html", import.meta.url);
const html = fs.readFileSync(signerPath, "utf8");
const inlineScript = html.match(/<script>\s*((?:.|\n)*?)\s*<\/script>\s*<\/body>/)?.[1];
assert.ok(inlineScript, "signer inline script must be present");

function makeElement() {
  return {
    className: "",
    disabled: false,
    textContent: "",
    value: "",
    classList: { add() {} },
    listeners: new Map(),
    addEventListener(name, callback) { this.listeners.set(name, callback); },
  };
}

function loadSigner({ currentChain = "0x1", switchError = null } = {}) {
  const elements = new Map();
  const requests = [];
  let posts = 0;
  const account = "0x58a92ed8a8df9bdcbfb0d7fba4fffec6d52c6008";
  const ethereum = {
    activeChain: currentChain,
    accounts: [account],
    driftDuringSign: false,
    listeners: new Map(),
    on(name, callback) { this.listeners.set(name, callback); },
    async request(request) {
      requests.push(request);
      if (request.method === "eth_requestAccounts" || request.method === "eth_accounts") {
        return this.accounts;
      }
      if (request.method === "eth_chainId") return this.activeChain;
      if (request.method === "wallet_switchEthereumChain") {
        if (switchError) {
          const error = switchError;
          switchError = null;
          throw error;
        }
        this.activeChain = request.params[0].chainId;
        return null;
      }
      if (request.method === "wallet_addEthereumChain") {
        this.activeChain = request.params[0].chainId;
        return null;
      }
      throw new Error(`unexpected request: ${request.method}`);
    },
  };
  const context = {
    URL,
    URLSearchParams,
    console,
    fetch: async () => {
      posts += 1;
      return { ok: true };
    },
    window: {
      ethereum,
      location: {
        search: "?provider_id=mp-test&verifying_contract=0xb1b26fc275b01d1071ec15a968ecd2d521c6acdae&chain_id=8453&chain=base-mainnet&nonce=0x" + "ab".repeat(32) + "&ts_utc=1786269537&redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fcb&state=deadbeef",
      },
    },
    document: {
      getElementById(id) {
        if (!elements.has(id)) elements.set(id, makeElement());
        return elements.get(id);
      },
    },
    ethers: {
      BrowserProvider: class {
        constructor(provider) { this.provider = provider; }
        async getSigner() {
          const provider = this.provider;
          return {
            getAddress: async () => account,
            signTypedData: async () => {
              if (provider.activeChain !== "0x2105") {
                throw new Error("chainId should be same as current chainId");
              }
              if (provider.driftDuringSign) {
                provider.accounts = ["0x1111111111111111111111111111111111111111"];
                provider.listeners.get("accountsChanged")?.(provider.accounts);
              }
              return "0x" + "cd".repeat(65);
            },
          };
        }
      },
      verifyTypedData: () => account,
    },
  };
  vm.runInNewContext(inlineScript, context, { filename: "signer.html" });
  return { elements, ethereum, getPosts: () => posts, requests };
}

async function clickAndSettle(elements, id) {
  elements.get(id).listeners.get("click")();
  await new Promise((resolve) => setImmediate(resolve));
}

test("connecting switches the wallet to the challenge chain before enabling signing", async () => {
  const { elements, requests } = loadSigner({ currentChain: "0x1" });
  await clickAndSettle(elements, "btnInjected");

  const switchRequest = requests.find((request) => request.method === "wallet_switchEthereumChain");
  assert.equal(switchRequest?.params[0].chainId, "0x2105");
  assert.equal(elements.get("btnSign").disabled, false);
});

test("a rejected chain switch leaves signing disabled with an actionable error", async () => {
  const rejection = Object.assign(new Error("User rejected the request."), { code: 4001 });
  const { elements } = loadSigner({ currentChain: "0x1", switchError: rejection });
  await clickAndSettle(elements, "btnInjected");

  assert.equal(elements.get("btnSign").disabled, true);
  assert.match(elements.get("status").textContent, /switch.*Base|Base.*switch/i);
});

test("an unknown Base network is offered to the wallet before signing", async () => {
  const unknownChain = Object.assign(new Error("Unrecognized chain ID"), { code: 4902 });
  const { elements, requests } = loadSigner({ currentChain: "0x1", switchError: unknownChain });
  await clickAndSettle(elements, "btnInjected");

  const addRequest = requests.find((request) => request.method === "wallet_addEthereumChain");
  assert.equal(addRequest?.params[0].chainId, "0x2105");
  assert.equal(addRequest?.params[0].chainName, "Base Mainnet");
  assert.equal(addRequest?.params[0].rpcUrls[0], "https://mainnet.base.org");
  assert.equal(elements.get("btnSign").disabled, false);
});

test("signing rechecks and repairs chain drift after connection", async () => {
  const { elements, ethereum, requests } = loadSigner({ currentChain: "0x2105" });
  await clickAndSettle(elements, "btnInjected");
  ethereum.activeChain = "0x1";

  await clickAndSettle(elements, "btnSign");

  const switches = requests.filter((request) => request.method === "wallet_switchEthereumChain");
  assert.equal(switches.length, 1);
  assert.equal(switches[0].params[0].chainId, "0x2105");
  assert.equal(elements.get("status").textContent, "Signature sent to Malibu. You can close this tab.");
});

test("returning to Base after a chainChanged event re-enables signing", async () => {
  const { elements, ethereum } = loadSigner({ currentChain: "0x2105" });
  await clickAndSettle(elements, "btnInjected");

  ethereum.listeners.get("chainChanged")("0x1");
  assert.equal(elements.get("btnSign").disabled, true);
  ethereum.listeners.get("chainChanged")("0x2105");

  assert.equal(elements.get("btnSign").disabled, false);
  assert.match(elements.get("status").textContent, /Connected on Base Mainnet/);
});

test("an account change during wallet approval prevents callback submission", async () => {
  const { elements, ethereum, getPosts } = loadSigner({ currentChain: "0x2105" });
  await clickAndSettle(elements, "btnInjected");
  ethereum.driftDuringSign = true;

  await clickAndSettle(elements, "btnSign");

  assert.equal(getPosts(), 0);
  assert.match(elements.get("status").textContent, /account or network changed/i);
});
