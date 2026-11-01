// Computes Sierra class hashes + compiled (CASM) class hashes of the release build and writes
// (--write) or verifies (--check) deployments/class-hashes.json.
// Usage: scarb --release build && node scripts/ci/class_hashes.mjs --check
import { hash } from "starknet";
import fs from "fs";
import path from "path";
import { execSync } from "child_process";
import { fileURLToPath } from "url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const OUT = path.join(ROOT, "target/release");
const MANIFEST = path.join(ROOT, "deployments/class-hashes.json");
const CONTRACTS = ["ConcLiquidityVault", "V1V2Migration", "TimelockController", "MultiExecutor"];

function load(name, kind) {
  const f = path.join(OUT, `troves_clvaults_${name}.${kind}.json`);
  if (!fs.existsSync(f)) throw new Error(`missing ${f} (run: scarb --release build)`);
  return JSON.parse(fs.readFileSync(f, "utf8"));
}

const scarbVersion = execSync("scarb --version", { encoding: "utf8" }).split("\n").slice(0, 2).join(" | ").trim();
const current = {
  toolchain: scarbVersion,
  profile: "release",
  contracts: Object.fromEntries(
    CONTRACTS.map((c) => [
      c,
      {
        class_hash: hash.computeContractClassHash(load(c, "contract_class")),
        compiled_class_hash: hash.computeCompiledClassHash(load(c, "compiled_contract_class")),
      },
    ]),
  ),
};

const mode = process.argv[2] ?? "--check";
if (mode === "--write") {
  fs.mkdirSync(path.dirname(MANIFEST), { recursive: true });
  fs.writeFileSync(MANIFEST, JSON.stringify(current, null, 2) + "\n");
  console.log(`wrote ${path.relative(ROOT, MANIFEST)}`);
  console.log(JSON.stringify(current, null, 2));
} else {
  const committed = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
  let ok = committed.toolchain === current.toolchain;
  if (!ok) console.error(`toolchain mismatch: committed "${committed.toolchain}" vs "${current.toolchain}"`);
  for (const c of CONTRACTS) {
    const a = committed.contracts[c];
    const b = current.contracts[c];
    const same = a && a.class_hash === b.class_hash && a.compiled_class_hash === b.compiled_class_hash;
    console.log(`${same ? "OK  " : "DIFF"} ${c.padEnd(20)} ${b.class_hash}`);
    ok &&= same;
  }
  if (!ok) {
    console.error("\nClass hashes differ from deployments/class-hashes.json. If the change is intended, run:\n  scarb --release build && node scripts/ci/class_hashes.mjs --write");
    process.exit(1);
  }
}
