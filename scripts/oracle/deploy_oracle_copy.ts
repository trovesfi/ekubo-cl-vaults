/**
 * Troves-owned instance of the Vesu v2 oracle: same on-chain class (no new code, no re-audit),
 * Troves owner/manager controlling per-asset staleness / min-sources / Pragma keys.
 *
 * Steps (all read-only unless you sign and send the printed calls yourself):
 *  1. read Vesu's oracle class hash + Pragma addresses + per-asset configs from the live Vesu oracle
 *  2. build the UDC deploy call (constructor: owner, manager, pragma_oracle, pragma_summary)
 *  3. build add_asset(asset, config) calls (to be executed by the MANAGER, e.g. via the timelock)
 *  4. simulate deploy + add_asset with SKIP_VALIDATE (deployer / manager as sender)
 *
 * Env: RPC_URL, ORACLE_OWNER, ORACLE_MANAGER, DEPLOYER (any funded account address, for simulation),
 *      ASSETS (comma-separated token addresses; default: the CL-vault tokens below), SALT (optional).
 * Run: npx tsx scripts/oracle/deploy_oracle_copy.ts
 */
import { RpcProvider, CallData, hash, num, stark, transaction } from "starknet";

const VESU_ORACLE = "0xfe4bfb1b353ba51eb34dff963017f94af5a5cf8bdf3dfc191c504657f3c05";
const UDC = "0x041a78e741e5af2fec34b695679bc6891742439f7afb8484ecd7766661ad02bf";
const DEFAULT_ASSETS: Record<string, string> = {
  STRK: "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d",
  xSTRK: "0x028d709c875c0ceac3dce7065bec5328186dc89fe254527084d1689910954b0a",
  ETH: "0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7",
  USDC: "0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8",
  USDT: "0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8",
  WBTC: "0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac",
};

function env(name: string, fallback?: string): string {
  const v = process.env[name] ?? fallback;
  if (v === undefined) throw new Error(`missing env ${name}`);
  return v;
}

async function call(p: RpcProvider, to: string, fn: string, cd: string[] = []): Promise<string[]> {
  return p.callContract({ contractAddress: to, entrypoint: fn, calldata: cd });
}

async function main() {
  const provider = new RpcProvider({ nodeUrl: env("RPC_URL") });
  const owner = env("ORACLE_OWNER");
  const manager = env("ORACLE_MANAGER");
  const deployer = env("DEPLOYER", manager);
  const salt = env("SALT", stark.randomAddress());
  const assets = process.env.ASSETS ? process.env.ASSETS.split(",") : Object.values(DEFAULT_ASSETS);
  const nameOf = (a: string) => Object.entries(DEFAULT_ASSETS).find(([, v]) => num.toBigInt(v) === num.toBigInt(a))?.[0] ?? a;

  // 1. source of truth: live Vesu oracle
  const classHash = await provider.getClassHashAt(VESU_ORACLE);
  const [pragmaOracle] = await call(provider, VESU_ORACLE, "pragma_oracle");
  const [pragmaSummary] = await call(provider, VESU_ORACLE, "pragma_summary");
  console.log("Vesu v2 Oracle", VESU_ORACLE, "class", classHash);
  console.log("pragma_oracle", pragmaOracle, "pragma_summary", pragmaSummary);

  const configs: { asset: string; config: string[] }[] = [];
  for (const asset of assets) {
    const cfg = await call(provider, VESU_ORACLE, "oracle_config", [asset]);
    if (num.toBigInt(cfg[0]) === 0n) { console.warn(`! ${nameOf(asset)}: not configured on Vesu, skipped`); continue; }
    const key = Buffer.from(num.toHex(cfg[0]).slice(2), "hex").toString();
    console.log(`${nameOf(asset).padEnd(6)} key=${key} timeout=${num.toBigInt(cfg[1])}s min_sources=${num.toBigInt(cfg[2])} twap_offset=${num.toBigInt(cfg[3])} twap_window=${num.toBigInt(cfg[4])} mode=${cfg[5]}`);
    configs.push({ asset, config: cfg });
  }

  // 2. deploy via UDC (deployContract(class_hash, salt, not_from_zero=false, calldata))
  const ctor = CallData.compile({ owner, manager, pragma_oracle: pragmaOracle, pragma_summary: pragmaSummary });
  const deployCall = {
    contractAddress: UDC,
    entrypoint: "deployContract",
    calldata: CallData.compile({ classHash, salt, unique: 0, calldata: ctor }),
  };
  const oracleAddr = hash.calculateContractAddressFromHash(salt, classHash, ctor, 0);
  console.log("\nTroves oracle (precomputed):", oracleAddr);

  // 3. add_asset calls (executed by MANAGER)
  const addCalls = configs.map(({ asset, config }) => ({
    contractAddress: oracleAddr, entrypoint: "add_asset", calldata: [asset, ...config],
  }));

  console.log("\n== deploy (sender: DEPLOYER) ==\n", JSON.stringify(deployCall, null, 1));
  console.log("\n== add_asset batch (sender: MANAGER / timelock) ==\n", JSON.stringify(addCalls, null, 1));

  // 4. simulate: deploy as DEPLOYER, then add_asset as MANAGER, same block (SKIP_VALIDATE)
  const cairoVersionOf = async (a: string): Promise<"0" | "1"> => {
    const cls: any = await provider.getClassAt(a);
    return cls.sierra_program ? "1" : "0";
  };
  const versions = new Map<string, "0" | "1">();
  for (const a of [deployer, manager]) versions.set(num.toHex(a), await cairoVersionOf(a));
  const toInvoke = (sender: string, calls: any[]) => ({
    type: "INVOKE", version: "0x3", sender_address: sender, signature: [], nonce: "0x0",
    calldata: transaction.getExecuteCalldata(calls, versions.get(num.toHex(sender))!).map((x: any) => num.toHex(x)),
    resource_bounds: { l1_gas: { max_amount: "0x0", max_price_per_unit: "0x0" }, l2_gas: { max_amount: "0x0", max_price_per_unit: "0x0" }, l1_data_gas: { max_amount: "0x0", max_price_per_unit: "0x0" } },
    tip: "0x0", paymaster_data: [], account_deployment_data: [], nonce_data_availability_mode: "L1", fee_data_availability_mode: "L1",
  });
  const nonces = new Map<string, bigint>();
  const nonce = async (a: string) => {
    const k = num.toHex(a);
    const n = nonces.has(k) ? nonces.get(k)! : num.toBigInt(await provider.getNonceForAddress(a));
    nonces.set(k, n + 1n);
    return num.toHex(n);
  };
  const txs = [{ ...toInvoke(deployer, [deployCall]), nonce: await nonce(deployer) }];
  if (addCalls.length) txs.push({ ...toInvoke(manager, addCalls), nonce: await nonce(manager) });
  // read-back: price(asset) on the new instance, executed as an invoke so it sees simulated state
  const priceCalls = configs.map(({ asset }) => ({ contractAddress: oracleAddr, entrypoint: "price", calldata: [asset] }));
  if (priceCalls.length) txs.push({ ...toInvoke(deployer, priceCalls), nonce: await nonce(deployer) });
  const res = await fetch(env("RPC_URL"), {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "starknet_simulateTransactions", params: { block_id: "latest", transactions: txs, simulation_flags: ["SKIP_VALIDATE", "SKIP_FEE_CHARGE"] } }),
  }).then((r) => r.json());
  if (res.error) { console.error("\nSIMULATION ERROR", JSON.stringify(res.error).slice(0, 2000)); process.exit(1); }
  res.result.forEach((r: any, i: number) => {
    const ex = r.transaction_trace.execute_invocation;
    console.log(`\nsim tx ${i}: ${ex.revert_reason ? "REVERTED " + ex.revert_reason.slice(0, 1500) : "OK"}`);
  });

  // compare simulated prices of the new instance with the live Vesu oracle
  const priceTrace = res.result[res.result.length - 1]?.transaction_trace.execute_invocation;
  let ok = true;
  if (priceTrace && !priceTrace.revert_reason) {
    for (let i = 0; i < configs.length; i++) {
      const r: string[] = priceTrace.calls[i].result;
      const ours = num.toBigInt(r[0]) + (num.toBigInt(r[1]) << 128n);
      const v = await call(provider, VESU_ORACLE, "price", [configs[i].asset]);
      const theirs = num.toBigInt(v[0]) + (num.toBigInt(v[1]) << 128n);
      const valid = num.toBigInt(r[2]) === 1n;
      const same = ours === theirs;
      ok &&= valid && same;
      console.log(`${nameOf(configs[i].asset).padEnd(6)} troves=${ours} vesu=${theirs} valid=${valid} ${same ? "MATCH" : "DIFF"}`);
    }
  } else ok = false;
  console.log(ok ? "\nALL CHECKS PASSED" : "\nCHECKS FAILED");
  if (!ok) process.exit(1);
}

main().catch((e) => { console.error(e); process.exit(1); });
