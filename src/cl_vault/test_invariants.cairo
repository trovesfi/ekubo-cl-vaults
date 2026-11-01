// Fuzz + stateful invariant tests (fork). Properties:
//   P1 deposit never pulls more than offered; deposit->withdraw is never profitable and loses at
//      most the Ekubo withdrawal fee (+ dust)
//   P2 tiny deposits never mint shares worth more than what was paid
//   P3 (stateful, random op sequences over 3 users) after every step:
//      I1 total_supply == sum(user shares) + dead shares
//      I2 sum over users of convert_to_assets(shares) <= vault holdings (positions + idle), per token
//      I3 value per share never drops by more than the Ekubo withdrawal fee per step
//      I4 at the end every user can exit with their full balance
#[cfg(test)]
pub mod test_invariants {
    use troves_clvaults::cl_vault::interface::{
        IClVaultDispatcher, IClVaultDispatcherTrait, IClVaultSafeDispatcher,
        IClVaultSafeDispatcherTrait, RebalanceParams, RangeInstruction,
    };
    use snforge_std::{start_cheat_caller_address, stop_cheat_caller_address};
    use starknet::ContractAddress;
    use troves_clvaults::cl_vault::test_audit::test_audit::{
        E18, single_pool_vault, two_pool_vault, fund, approve_as, bal, deposit_as, rebalance_max,
        setup_live_vault, avnu_swap_self, pool_key_1, xstrk, strk, empty_swap,
    };
    use troves_clvaults::interfaces::IVesuOracle::{IVesuOracleDispatcher, IVesuOracleDispatcherTrait};
    use troves_clvaults::tests::utils as test_utils;

    const DEAD_SHARES: u256 = 1000;

    // ------------------------------------------------------------------ helpers

    // USD value (1e18-scaled prices from the live Vesu oracle at the fork block)
    fn value(a0: u256, a1: u256) -> u256 {
        let o = IVesuOracleDispatcher { contract_address: test_utils::VESU_ORACLE() };
        (a0 * o.price(xstrk()).value + a1 * o.price(strk()).value) / E18
    }

    fn bound(x: u256, lo: u256, hi: u256) -> u256 {
        lo + x % (hi - lo + 1)
    }

    // deterministic PRNG for op sequences (64-bit LCG on a u256 state)
    fn next(ref state: u256) -> u256 {
        state = (state * 6364136223846793005 + 1442695040888963407) % 0x10000000000000000;
        state
    }

    fn user(i: u256) -> ContractAddress {
        let x: felt252 = (0xA000 + i).try_into().unwrap();
        x.try_into().unwrap()
    }

    fn withdraw_as(vault: IClVaultDispatcher, who: ContractAddress, shares: u256) -> (u256, u256) {
        start_cheat_caller_address(vault.contract_address, who);
        let out = vault.withdraw(shares, who);
        stop_cheat_caller_address(vault.contract_address);
        (out.total_amount0, out.total_amount1)
    }

    fn vault_holdings(vault: IClVaultDispatcher) -> (u256, u256) {
        let p = vault.get_positions();
        (
            p.total_amount0 + bal(xstrk(), vault.contract_address),
            p.total_amount1 + bal(strk(), vault.contract_address),
        )
    }

    // value of 1e18 shares (scaled), from convert_to_assets
    fn value_per_share(vault: IClVaultDispatcher) -> u256 {
        let a = vault.convert_to_assets(E18);
        value(a.total_amount0, a.total_amount1)
    }

    fn check_invariants(vault: IClVaultDispatcher, n_users: u256) {
        let supply = bal(vault.contract_address, vault.contract_address);
        // I1
        let mut sum_shares = supply; // dead shares held by the vault itself
        let mut claim0: u256 = 0;
        let mut claim1: u256 = 0;
        let mut i: u256 = 0;
        while i != n_users {
            let s = bal(vault.contract_address, user(i));
            sum_shares += s;
            if s > 0 {
                let a = vault.convert_to_assets(s);
                claim0 += a.total_amount0;
                claim1 += a.total_amount1;
            }
            i += 1;
        };
        let ts = troves_clvaults::helpers::ERC20Helper::total_supply(vault.contract_address);
        assert(sum_shares == ts, 'I1 supply != sum of shares');
        assert(supply == DEAD_SHARES || ts == 0, 'I1 dead shares changed');
        // I2
        let (h0, h1) = vault_holdings(vault);
        assert(claim0 <= h0 && claim1 <= h1, 'I2 claims exceed holdings');
    }

    // ------------------------------------------------------------------ P1

    #[test]
    #[fork("mainnet_4707139")]
    #[fuzzer(runs: 12, seed: 2026)]
    fn fuzz_deposit_withdraw_roundtrip(x0: u256, x1: u256) {
        let vault = setup_live_vault();
        let bob = user(1);
        let a0 = bound(x0, 1_000_000_000_000, 50 * E18);
        let a1 = bound(x1, 1_000_000_000_000, 50 * E18);
        fund(bob, 200 * E18);
        let b0 = bal(xstrk(), bob);
        let b1 = bal(strk(), bob);
        let shares = deposit_as(vault, bob, a0, a1, 200 * E18);
        let paid0 = b0 - bal(xstrk(), bob);
        let paid1 = b1 - bal(strk(), bob);
        assert(paid0 <= a0 && paid1 <= a1, 'P1 pulled > offered');
        assert(shares > 0, 'P1 no shares');
        let (got0, got1) = withdraw_as(vault, bob, shares);
        assert(got0 <= paid0 && got1 <= paid1, 'P1 roundtrip profitable');
        // Ekubo withdrawal fee <= pool fee (0.01%): allow 0.1% + 1e6 wei dust
        let vp = value(paid0, paid1);
        assert(value(got0, got1) * 1000 + 1_000_000 >= vp * 999, 'P1 roundtrip loss too big');
    }

    // ------------------------------------------------------------------ P2

    #[test]
    #[feature("safe_dispatcher")]
    #[fork("mainnet_4707139")]
    #[fuzzer(runs: 12, seed: 7)]
    fn fuzz_tiny_deposits_no_free_shares(x0: u256, x1: u256) {
        let vault = setup_live_vault();
        let bob = user(2);
        let a0 = bound(x0, 0, 1_000_000_000);
        let a1 = bound(x1, 0, 1_000_000_000);
        fund(bob, E18);
        approve_as(bob, xstrk(), vault.contract_address, E18);
        approve_as(bob, strk(), vault.contract_address, E18);
        let b0 = bal(xstrk(), bob);
        let b1 = bal(strk(), bob);
        let safe = IClVaultSafeDispatcher { contract_address: vault.contract_address };
        start_cheat_caller_address(vault.contract_address, bob);
        let res = safe.deposit(a0, a1, bob);
        stop_cheat_caller_address(vault.contract_address);
        match res {
            Result::Ok(shares) => {
                let paid0 = b0 - bal(xstrk(), bob);
                let paid1 = b1 - bal(strk(), bob);
                let a = vault.convert_to_assets(shares);
                assert(
                    value(a.total_amount0, a.total_amount1) <= value(paid0, paid1),
                    'P2 shares worth > paid',
                );
            },
            // reverting (zero shares / zero amounts) is acceptable for dust
            Result::Err(_) => {},
        }
    }

    // ------------------------------------------------------------------ P3 (stateful)

    // op: 0 deposit, 1 partial withdraw, 2 fee-generating external swaps + handle_fees,
    //     3 rebalance (burn a random fraction everywhere, re-mint max), 4 full exit of one user
    fn run_sequence(vault: IClVaultDispatcher, seed: u256, steps: u32) {
        let n_users: u256 = 3;
        let mut state = seed % 0x10000000000000000;
        let mut i: u256 = 0;
        while i != n_users {
            fund(user(i), 500 * E18);
            i += 1;
        };
        // bootstrap: first depositor + first rebalance
        deposit_as(vault, user(0), 20 * E18, 20 * E18, 500 * E18);
        rebalance_max(vault);
        check_invariants(vault, n_users);

        let this = starknet::get_contract_address();
        fund(this, 5000 * E18);
        let mut step: u32 = 0;
        while step != steps {
            let price_before = value_per_share(vault);
            let op = next(ref state) % 5;
            let who = user(next(ref state) % n_users);
            if op == 0 {
                let a0 = bound(next(ref state), E18 / 100, 30 * E18);
                let a1 = bound(next(ref state), E18 / 100, 30 * E18);
                deposit_as(vault, who, a0, a1, 500 * E18);
            } else if op == 1 {
                let s = bal(vault.contract_address, who);
                let frac = bound(next(ref state), 1, 100);
                let w = s * frac / 100;
                if w > 0 {
                    withdraw_as(vault, who, w);
                }
            } else if op == 2 {
                let key = pool_key_1();
                avnu_swap_self(strk(), xstrk(), bound(next(ref state), E18, 300 * E18), key);
                avnu_swap_self(xstrk(), strk(), bound(next(ref state), E18, 250 * E18), key);
                vault.handle_fees(0);
            } else if op == 3 {
                let pools = vault.get_managed_pools();
                let frac = bound(next(ref state), 1, 100);
                let mut ins: Array<RangeInstruction> = array![];
                let mut p: u32 = 0;
                while p != pools.len() {
                    let pool = *pools.at(p);
                    let liq: u256 = vault.total_liquidity_per_pool(p.into());
                    ins
                        .append(
                            RangeInstruction {
                                liquidity_mint: 0,
                                liquidity_burn: (liq * frac / 100).try_into().unwrap(),
                                pool_key: pool.pool_key,
                                new_bounds: pool.bounds,
                            },
                        );
                    p += 1;
                };
                vault.rebalance_pool(RebalanceParams { rebal: ins, swap_params: empty_swap(vault) });
                rebalance_max(vault);
            } else {
                let s = bal(vault.contract_address, who);
                if s > 0 {
                    withdraw_as(vault, who, s);
                }
            }
            check_invariants(vault, n_users);
            // I3: value per share never drops by more than 0.1% per step
            let ts = troves_clvaults::helpers::ERC20Helper::total_supply(vault.contract_address);
            if ts > DEAD_SHARES * 1_000_000 {
                let price_after = value_per_share(vault);
                assert(price_after * 1000 >= price_before * 999, 'I3 share value dropped');
            }
            step += 1;
        };

        // I4: everyone can exit
        let mut i: u256 = 0;
        while i != n_users {
            let s = bal(vault.contract_address, user(i));
            if s > 0 {
                let quote = vault.convert_to_assets(s);
                let (g0, g1) = withdraw_as(vault, user(i), s);
                assert(
                    value(g0, g1) * 1000 + 1_000_000 >= value(quote.total_amount0, quote.total_amount1) * 999,
                    'I4 exit below quote',
                );
            }
            i += 1;
        };
        check_invariants(vault, n_users);
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[fuzzer(runs: 8, seed: 42)]
    fn fuzz_invariants_single_pool(seed: u256) {
        run_sequence(single_pool_vault(), seed, 8);
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[fuzzer(runs: 6, seed: 4242)]
    fn fuzz_invariants_two_pools(seed: u256) {
        run_sequence(two_pool_vault(), seed, 8);
    }

    // regression (found by fuzz_invariants_single_pool): after every user exits, the vault holds
    // dust against the dead shares; the next deposit must still succeed and be fairly priced
    #[test]
    #[fork("mainnet_4707139")]
    fn test_deposit_after_everyone_exited() {
        let vault = setup_live_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        // generate some fees so ranges hold odd dust after exit
        let this = starknet::get_contract_address();
        fund(this, 1000 * E18);
        avnu_swap_self(strk(), xstrk(), 200 * E18, pool_key_1());
        avnu_swap_self(xstrk(), strk(), 150 * E18, pool_key_1());
        withdraw_as(vault, alice, bal(vault.contract_address, alice));
        let bob = user(9);
        fund(bob, 100 * E18);
        let b0 = bal(xstrk(), bob);
        let b1 = bal(strk(), bob);
        let shares = deposit_as(vault, bob, 15 * E18, 15 * E18, 100 * E18);
        let paid0 = b0 - bal(xstrk(), bob);
        let paid1 = b1 - bal(strk(), bob);
        assert(paid0 <= 15 * E18 && paid1 <= 15 * E18, 'pulled > offered');
        let (g0, g1) = withdraw_as(vault, bob, shares);
        assert(value(g0, g1) * 1000 + 1_000_000 >= value(paid0, paid1) * 999, 'unfair after reset');
    }
}
