import dotenv from 'dotenv';
dotenv.config();
import { ContractAddr, DualActionAmount, EkuboCLVaultV2, EkuboCLVaultV2Strategies, getMainnetConfig, Global, Pricer, PricerFromApi, PricerRedis, Web3Number } from "@strkfarm/sdk";
import { getAccount, getRpcProvider } from "../lib/utils";
import { STRK, xSTRK } from "../lib/constants";
import { TransactionExecutionStatus } from "starknet";

async function main() {
    const provider = getRpcProvider(process.env.RPC_URL);
    const config = getMainnetConfig(process.env.RPC_URL);
    // const pricer = new PricerRedis(config, await Global.getTokens());
    // await pricer.initRedis(process.env.REDIS_URL!);
    const pricer = new PricerFromApi(config, await Global.getTokens());
    console.log('Pricer ready');

    // Use v2 vault for xSTRK/STRK
    const mod = new EkuboCLVaultV2(config, pricer, EkuboCLVaultV2Strategies[0]);
    console.log(`Using vault: ${mod.metadata.name} at ${mod.address.address}`);

    const acc = getAccount('strkfarmadmin');
    const caller = ContractAddr.from(acc.address);

    // Get token info
    const token0Info = mod.metadata.depositTokens[0];
    const token1Info = mod.metadata.depositTokens[1];
    console.log(`Token0: ${token0Info.symbol}, Token1: ${token1Info.symbol}`);

    // Prepare deposit amounts: 1 xSTRK and 1 STRK
    // const depositInputs: DualActionAmount = {
    //     token0: {
    //         tokenInfo: token0Info,
    //         amount: new Web3Number(1, token0Info.decimals) // 1 xSTRK
    //     },
    //     token1: {
    //         tokenInfo: token1Info,
    //         amount: new Web3Number(1, token1Info.decimals) // 1 STRK
    //     }
    // };
    // // return;

    // console.log(`Deposit inputs: token0: ${depositInputs.token0.amount.toWei()} ${token0Info.symbol}, token1: ${depositInputs.token1.amount.toWei()} ${token1Info.symbol}`);

    // Match input amounts to get optimal deposit amounts
    // const matchedAmounts = await mod.matchInputAmounts(depositInputs);
    // console.log(`Matched amounts: token0: ${matchedAmounts.token0.amount.toString()}, token1: ${matchedAmounts.token1.amount.toString()}`);

    // // Get minimum deposit amounts
    // const depositAmounts = await mod.getMinDepositAmounts(matchedAmounts);
    // console.log(`Deposit amounts: token0: ${depositAmounts.token0.amount.toString()}, token1: ${depositAmounts.token1.amount.toString()}`);

    // Create deposit calls
    // const depositCalls = await mod.depositCall(depositInputs, caller);
    // console.log(`Prepared ${depositCalls.length} deposit calls`);
    // console.log('depositCalls', depositCalls);
    // return;

    // Execute deposit
    // const tx = await acc.execute(depositCalls);
    // console.log(`Deposit tx: ${tx.transaction_hash}`);
    // await provider.waitForTransaction(tx.transaction_hash, {
    //     successStates: [TransactionExecutionStatus.SUCCEEDED]
    // });
    // console.log('Deposit done');

    // Check balance after deposit
    const myShares = await mod.balanceOf(caller);
    console.log(`My shares: ${myShares.toString()}`);

    const userTVL = await mod.getUserTVL(caller);
    console.log(`User TVL: ${JSON.stringify(userTVL, null, 2)}`);
}

async function harvest() {
    const provider = getRpcProvider();
    const config = getMainnetConfig();
    const pricer = new PricerFromApi(config, await Global.getTokens());
    console.log('Pricer ready');

    const mod = new EkuboCLVaultV2(config, pricer, EkuboCLVaultV2Strategies[0]);
    const riskAcc = getAccount('risk-manager', 'accounts-risk.json', process.env.ACCOUNT_SECURE_PASSWORD_RISK);
    const calls = await mod.harvest(riskAcc);
    if (calls.length) {
        // console.log('harvest ready');
        const tx = await riskAcc.execute(calls);
        console.log(`Harvest tx: ${tx.transaction_hash}`);
        await provider.waitForTransaction(tx.transaction_hash, {
            successStates: [TransactionExecutionStatus.SUCCEEDED]
        });
        console.log('Harvest done');
    } else {
        console.log('No harvest calls');
    }
}

if (require.main === module) {
    main();
    // harvest();
}