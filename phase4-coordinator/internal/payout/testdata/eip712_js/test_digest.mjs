#!/usr/bin/env node
/**
 * Cross-language EIP-712 digest fixture: ethers.TypedDataEncoder.hash
 * MUST equal the Go buildDigest hex committed in
 * ../eip712_digest_fixture.json.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { TypedDataEncoder } from "ethers";

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(
  readFileSync(join(__dirname, "..", "eip712_digest_fixture.json"), "utf8")
);

const domain = fixture.domain;
const types = {
  PayoutAddressRegistration: fixture.types.PayoutAddressRegistration,
};
const value = {
  providerId: fixture.value.providerId,
  address: fixture.value.address,
  chain: fixture.value.chain,
  nonce: fixture.value.nonce,
  tsUtc: BigInt(fixture.value.tsUtc),
};

const hash = TypedDataEncoder.hash(domain, types, value);
if (hash.toLowerCase() !== String(fixture.digest).toLowerCase()) {
  console.error("DIGEST MISMATCH");
  console.error("  ethers:", hash);
  console.error("  fixture:", fixture.digest);
  process.exit(1);
}
console.log("ok digest", hash);
