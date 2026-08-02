#!/usr/bin/env node
/**
 * Sign the fixed EIP-712 typed data with a THROWAWAY test private key
 * (Hardhat account #1 — NEVER a production secret). Writes
 * roundtrip_signature.json for the Go VerifyEIP712 round-trip test.
 */
import { writeFileSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Wallet, TypedDataEncoder } from "ethers";

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(
  readFileSync(join(__dirname, "..", "eip712_digest_fixture.json"), "utf8")
);

// Hardhat/Anvil account #1 — public test vector only.
const THROWAWAY_PRIV =
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const wallet = new Wallet(THROWAWAY_PRIV);

const domain = fixture.domain;
const types = {
  PayoutAddressRegistration: fixture.types.PayoutAddressRegistration,
};

// The registered address MUST be the signing account for VerifyEIP712.
const address = await wallet.getAddress();
// Recompute digest with the throwaway signer's address (fixture address
// may differ; round-trip uses the key's derived address).
const value = {
  providerId: fixture.providerId,
  address,
  chain: fixture.chain,
  nonce: fixture.nonce,
  tsUtc: BigInt(fixture.tsUtc),
};

const signature = await wallet.signTypedData(domain, types, value);
const recovered = TypedDataEncoder.hash
  ? undefined
  : undefined;
// Sanity: recover via verifyTypedData
import { verifyTypedData } from "ethers";
const verified = verifyTypedData(domain, types, value, signature);
if (verified.toLowerCase() !== address.toLowerCase()) {
  console.error("self-verify failed", verified, address);
  process.exit(1);
}

const out = {
  providerId: fixture.providerId,
  address,
  chain: fixture.chain,
  nonce: fixture.nonce,
  tsUtc: fixture.tsUtc,
  verifyingContract: fixture.domain.verifyingContract,
  signature,
  note: "Throwaway Hardhat account #1 only — never a production key.",
};
writeFileSync(
  join(__dirname, "roundtrip_signature.json"),
  JSON.stringify(out, null, 2) + "\n"
);
console.log("ok signed", address, signature.slice(0, 18) + "...");
