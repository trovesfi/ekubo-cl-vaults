/**
 * Allowed timelock classes for the CL vault (constructor `allowed_timelocks` / migration arg):
 *  - OZ TimelockController (src/governance/timelock.cairo)      -> get_min_delay
 *  - StarkWare MultiExecutor (starkware-starknet-utils@3e2fd53) -> get_execution_delay
 * Class hashes are computed from this repo's build (`scarb build`), so they match what gets declared.
 * Run: npx tsx scripts/lib/timelock_classes.ts   (prints the JSON for CL_VAULT_ALLOWED_TIMELOCKS)
 */
import { hash, selector } from "starknet";
import fs from "fs";
import path from "path";

const TARGET = path.join(__dirname, "../../target/dev");

function classHash(contract: string): string {
  const file = path.join(TARGET, `troves_clvaults_${contract}.contract_class.json`);
  if (!fs.existsSync(file)) throw new Error(`missing ${file}: run 'scarb build' first`);
  return hash.computeContractClassHash(JSON.parse(fs.readFileSync(file, "utf8")));
}

export function allowedTimelockClasses() {
  return [
    { class_hash: classHash("TimelockController"), delay_selector: selector.getSelectorFromName("get_min_delay") },
    { class_hash: classHash("MultiExecutor"), delay_selector: selector.getSelectorFromName("get_execution_delay") },
  ];
}

if (require.main === module) {
  console.log(JSON.stringify(allowedTimelockClasses(), null, 2));
}
