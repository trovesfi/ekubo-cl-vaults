// Audit regression tests (fork). Each test asserts the SECURE behaviour, so on the
// pre-hardening code (main @ aa77b9d) they fail; after the fixes they pass.
//   C1  relayer can drain the vault through rebalance_pool's swap
//   C2  deposit pulls vault-level amounts / inverted limiting-token branch
//   H3  emptied pool (nft_id = 0) bricks withdraw; rebalance burns without collecting fees
//   H5  divide-by-zero when amount1 == 0
#[cfg(test)]
pub mod test_audit {
    use troves_clvaults::cl_vault::interface::{
        IClVaultDispatcher, IClVaultDispatcherTrait, FeeSettings, InitValues, ManagedPool,
        RebalanceParams, RangeInstruction,
    };
    use snforge_std::{
        declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address,
        stop_cheat_caller_address,
    };
    use starknet::{ContractAddress, get_contract_address};
    use strkfarm_contracts::helpers::{constants, ERC20Helper, pow};
    use strkfarm_contracts::components::swap::{
        AvnuMultiRouteSwap, Route, IAvnuDispatcher, IAvnuDispatcherTrait,
    };
    use troves_clvaults::interfaces::IEkuboCore::{Bounds, PoolKey};
    use troves_clvaults::interfaces::IEkuboPosition::{IEkuboDispatcher, IEkuboDispatcherTrait};
    use ekubo::types::i129::i129;
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
    use ekubo::types::keys::PoolKey as EkPoolKey;
    use ekubo::types::bounds::Bounds as EkBounds;
    use openzeppelin::utils::serde::SerializedAppend;
    use troves_clvaults::tests::utils as test_utils;

    const E18: u256 = 1_000_000_000_000_000_000;

    // ---------------------------------------------------------------- setup helpers

    fn xstrk() -> ContractAddress {
        constants::XSTRK_ADDRESS()
    }
    fn strk() -> ContractAddress {
        constants::STRK_ADDRESS()
    }

    fn pool_key_1() -> PoolKey {
        PoolKey {
            token0: xstrk(),
            token1: strk(),
            fee: 34028236692093847977029636859101184, // 0.01%
            tick_spacing: 200,
            extension: 0.try_into().unwrap(),
        }
    }

    fn pool_key_2() -> PoolKey {
        PoolKey {
            token0: xstrk(),
            token1: strk(),
            fee: 170141183460469235273462165868118016, // 0.05%
            tick_spacing: 1000,
            extension: 0.try_into().unwrap(),
        }
    }

    fn bounds_1() -> Bounds {
        Bounds { lower: i129 { mag: 104000, sign: false }, upper: i129 { mag: 124000, sign: false } }
    }

    fn bounds_2() -> Bounds {
        Bounds { lower: i129 { mag: 100000, sign: false }, upper: i129 { mag: 130000, sign: false } }
    }

    fn deploy_vault(pools: Array<ManagedPool>) -> IClVaultDispatcher {
        let access_control = test_utils::deploy_access_control();
        let cls = declare("ConcLiquidityVault").unwrap().contract_class();
        let name: ByteArray = "uCL_token";
        let symbol: ByteArray = "UCL";
        let fee_settings = FeeSettings {
            fee_bps: 1000, fee_collector: constants::EKUBO_FEE_COLLECTOR(),
        };
        let init_values = InitValues { init0: E18, init1: 2 * E18 };
        let mut calldata: Array<felt252> = array![];
        calldata.append_serde(name);
        calldata.append_serde(symbol);
        calldata.append(access_control.into());
        calldata.append(constants::EKUBO_POSITIONS().into());
        calldata.append(constants::EKUBO_POSITIONS_NFT().into());
        calldata.append(constants::EKUBO_CORE().into());
        calldata.append(constants::ORACLE_OURS().into());
        fee_settings.serialize(ref calldata);
        init_values.serialize(ref calldata);
        pools.serialize(ref calldata);
        let (address, _) = cls.deploy(@calldata).expect('ClVault deploy failed');
        IClVaultDispatcher { contract_address: address }
    }

    fn single_pool_vault() -> IClVaultDispatcher {
        deploy_vault(array![ManagedPool { pool_key: pool_key_1(), bounds: bounds_1(), nft_id: 0 }])
    }

    fn two_pool_vault() -> IClVaultDispatcher {
        deploy_vault(
            array![
                ManagedPool { pool_key: pool_key_1(), bounds: bounds_1(), nft_id: 0 },
                ManagedPool { pool_key: pool_key_2(), bounds: bounds_2(), nft_id: 0 },
            ],
        )
    }

    // whale = Ekubo core (holds plenty of both tokens on the fork)
    fn fund(user: ContractAddress, amount: u256) {
        let whale = constants::EKUBO_CORE();
        start_cheat_caller_address(strk(), whale);
        ERC20Helper::transfer(strk(), user, amount);
        stop_cheat_caller_address(strk());
        start_cheat_caller_address(xstrk(), whale);
        ERC20Helper::transfer(xstrk(), user, amount);
        stop_cheat_caller_address(xstrk());
    }

    fn approve_as(user: ContractAddress, token: ContractAddress, spender: ContractAddress, amt: u256) {
        start_cheat_caller_address(token, user);
        ERC20Helper::approve(token, spender, amt);
        stop_cheat_caller_address(token);
    }

    fn bal(token: ContractAddress, who: ContractAddress) -> u256 {
        ERC20Helper::balanceOf(token, who)
    }

    fn deposit_as(
        vault: IClVaultDispatcher, user: ContractAddress, a0: u256, a1: u256, allowance: u256,
    ) -> u256 {
        approve_as(user, xstrk(), vault.contract_address, allowance);
        approve_as(user, strk(), vault.contract_address, allowance);
        start_cheat_caller_address(vault.contract_address, user);
        let shares = vault.deposit(a0, a1, user);
        stop_cheat_caller_address(vault.contract_address);
        shares
    }

    fn empty_swap(vault: IClVaultDispatcher) -> AvnuMultiRouteSwap {
        AvnuMultiRouteSwap {
            token_from_address: xstrk(),
            token_from_amount: 0,
            token_to_address: strk(),
            token_to_amount: 0,
            token_to_min_amount: 0,
            beneficiary: vault.contract_address,
            integrator_fee_amount_bps: 0,
            integrator_fee_recipient: 0.try_into().unwrap(),
            routes: array![],
        }
    }

    // Mint as much liquidity as the vault's idle balances allow, split evenly across pools.
    fn rebalance_max(vault: IClVaultDispatcher) {
        let pools = vault.get_managed_pools();
        let n: u256 = pools.len().into();
        let this_bal0 = bal(xstrk(), vault.contract_address);
        let this_bal1 = bal(strk(), vault.contract_address);
        let mut ins: Array<RangeInstruction> = array![];
        let mut i: u32 = 0;
        while i != pools.len() {
            let pool = *pools.at(i);
            // 98% of the per-pool share to leave room for rounding
            let liq = vault
                .get_liquidity_delta(
                    i.into(), this_bal0 * 98 / 100 / n, this_bal1 * 98 / 100 / n,
                );
            ins
                .append(
                    RangeInstruction {
                        liquidity_mint: liq,
                        liquidity_burn: 0,
                        pool_key: pool.pool_key,
                        new_bounds: pool.bounds,
                    },
                );
            i += 1;
        };
        vault.rebalance_pool(RebalanceParams { rebal: ins, swap_params: empty_swap(vault) });
    }

    // Vault value in token1 units at the pool-1 spot price (positions + idle).
    fn vault_value_in_token1(vault: IClVaultDispatcher) -> u256 {
        let positions = vault.get_positions();
        let idle0 = bal(xstrk(), vault.contract_address);
        let idle1 = bal(strk(), vault.contract_address);
        let a0 = positions.total_amount0 + idle0;
        let a1 = positions.total_amount1 + idle1;
        // xSTRK ~ 1.1-1.2 STRK on this fork; 1.1 is enough for a loss-magnitude check
        a1 + a0 * 11 / 10
    }

    // Direct AVNU swap from the test contract (used to generate LP fees).
    fn avnu_swap_self(from: ContractAddress, to: ContractAddress, amount: u256, key: PoolKey) {
        let this = get_contract_address();
        ERC20Helper::approve(from, constants::AVNU_EX(), amount);
        let params: Array<felt252> = array![
            key.token0.into(), key.token1.into(), key.fee.into(), key.tick_spacing.into(),
            key.extension.into(), 10000000000000000000000000000000000000000000000000000000000000000000000,
        ];
        let route = Route {
            token_from: from,
            token_to: to,
            exchange_address: constants::EKUBO_CORE(),
            percent: 1000000000000,
            additional_swap_params: params,
        };
        IAvnuDispatcher { contract_address: constants::AVNU_EX() }
            .multi_route_swap(from, amount, to, 0, 1, this, 0, this, array![route]);
    }

    // ============================================================================
    // C2: deposit must only pull what the depositor offered, and give fair shares
    // ============================================================================

    fn setup_live_vault() -> IClVaultDispatcher {
        let vault = single_pool_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        fund(alice, 100 * E18);
        deposit_as(vault, alice, 10 * E18, 10 * E18, 10 * E18);
        rebalance_max(vault);
        vault
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_c2_second_deposit_pulls_only_offered_amounts() {
        let vault = setup_live_vault();
        let bob: ContractAddress = 0xB0B.try_into().unwrap();
        fund(bob, 1000 * E18);
        let b0_before = bal(xstrk(), bob);
        let b1_before = bal(strk(), bob);

        // Bob offers 1/1 but (like most wallets) has a large allowance
        let shares = deposit_as(vault, bob, E18, E18, 1000 * E18);

        let spent0 = b0_before - bal(xstrk(), bob);
        let spent1 = b1_before - bal(strk(), bob);
        println!("C2: bob offered 1e18/1e18, spent0={} spent1={} shares={}", spent0, spent1, shares);
        assert(spent0 <= E18, 'C2: pulled > offered token0');
        assert(spent1 <= E18, 'C2: pulled > offered token1');

        // shares must be worth (roughly) what Bob paid: >= 99%
        let assets = vault.convert_to_assets(shares);
        let paid_value = spent1 + spent0 * 11 / 10;
        let got_value = assets.total_amount1 + assets.total_amount0 * 11 / 10;
        println!("C2: paid_value={} share_value={}", paid_value, got_value);
        assert(got_value * 100 >= paid_value * 99, 'C2: shares under-priced');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_c2_limiting_token_low_token0() {
        let vault = setup_live_vault();
        let bob: ContractAddress = 0xB0B.try_into().unwrap();
        fund(bob, 1000 * E18);
        let b0_before = bal(xstrk(), bob);
        let b1_before = bal(strk(), bob);
        // token0 is the limiting token; exact allowances
        approve_as(bob, xstrk(), vault.contract_address, E18);
        approve_as(bob, strk(), vault.contract_address, 100 * E18);
        start_cheat_caller_address(vault.contract_address, bob);
        let shares = vault.deposit(E18, 100 * E18, bob);
        stop_cheat_caller_address(vault.contract_address);
        assert(shares > 0, 'no shares');
        assert(b0_before - bal(xstrk(), bob) <= E18, 'C2: over-pull token0');
        assert(b1_before - bal(strk(), bob) <= 100 * E18, 'C2: over-pull token1');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_c2_limiting_token_low_token1() {
        let vault = setup_live_vault();
        let bob: ContractAddress = 0xB0B.try_into().unwrap();
        fund(bob, 1000 * E18);
        let b0_before = bal(xstrk(), bob);
        let b1_before = bal(strk(), bob);
        approve_as(bob, xstrk(), vault.contract_address, 100 * E18);
        approve_as(bob, strk(), vault.contract_address, E18);
        start_cheat_caller_address(vault.contract_address, bob);
        let shares = vault.deposit(100 * E18, E18, bob);
        stop_cheat_caller_address(vault.contract_address);
        assert(shares > 0, 'no shares');
        assert(b0_before - bal(xstrk(), bob) <= 100 * E18, 'C2: over-pull token0');
        assert(b1_before - bal(strk(), bob) <= E18, 'C2: over-pull token1');
    }

    // H5: amount1 == 0 must not hit a raw division by zero
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('zero shares',))]
    fn test_h5_deposit_token0_only_in_range() {
        let vault = setup_live_vault();
        let bob: ContractAddress = 0xB0B.try_into().unwrap();
        fund(bob, 1000 * E18);
        deposit_as(vault, bob, E18, 0, E18);
    }

    // ============================================================================
    // C1: relayer must not be able to route vault funds through a pool it controls
    // ============================================================================

    // Attacker pool: xSTRK/STRK, unused fee tier, initialised at ~1e-4 STRK per xSTRK, with a
    // tiny amount of STRK spread down to MIN_TICK so it absorbs any amount of xSTRK.
    fn attacker_pool_key() -> EkPoolKey {
        EkPoolKey {
            token0: xstrk(),
            token1: strk(),
            fee: 0,
            tick_spacing: 999,
            extension: 0.try_into().unwrap(),
        }
    }

    fn setup_attacker_pool() -> (u64, EkBounds) {
        let key = attacker_pool_key();
        let core = ICoreDispatcher { contract_address: constants::EKUBO_CORE() };
        // tick -9_000_000 => price ~= 1.000001^-9e6 ~= 1.2e-4
        core.initialize_pool(key, i129 { mag: 9_000_000, sign: true });
        let bounds = EkBounds {
            lower: i129 { mag: 88_722_189, sign: true }, // 88811 * 999
            upper: i129 { mag: 9_209_781, sign: true }, // 9219 * 999
        };
        let positions = IPositionsDispatcher { contract_address: constants::EKUBO_POSITIONS() };
        let this = get_contract_address();
        fund(this, 10 * E18);
        ERC20Helper::transfer(strk(), constants::EKUBO_POSITIONS(), E18); // 1 STRK bait
        let (id, _liq, _c0, _c1) = positions.mint_and_deposit_and_clear_both(key, bounds, 0);
        (id, bounds)
    }

    fn drain_swap(vault: IClVaultDispatcher, amount: u256, min_out: u256) -> AvnuMultiRouteSwap {
        let key = attacker_pool_key();
        let params: Array<felt252> = array![
            key.token0.into(), key.token1.into(), key.fee.into(), key.tick_spacing.into(),
            key.extension.into(), 10000000000000000000000000000000000000000000000000000000000000000000000,
        ];
        AvnuMultiRouteSwap {
            token_from_address: xstrk(),
            token_from_amount: amount,
            token_to_address: strk(),
            token_to_amount: 0,
            token_to_min_amount: min_out, // 1 => skips the oracle check on main
            beneficiary: vault.contract_address,
            integrator_fee_amount_bps: 0,
            integrator_fee_recipient: 0.try_into().unwrap(),
            routes: array![
                Route {
                    token_from: xstrk(),
                    token_to: strk(),
                    exchange_address: constants::EKUBO_CORE(),
                    percent: 1000000000000,
                    additional_swap_params: params,
                },
            ],
        }
    }

    fn burn_all_and_swap(vault: IClVaultDispatcher, swap: AvnuMultiRouteSwap) {
        let pools = vault.get_managed_pools();
        let mut ins: Array<RangeInstruction> = array![];
        let mut i: u32 = 0;
        while i != pools.len() {
            let pool = *pools.at(i);
            ins
                .append(
                    RangeInstruction {
                        liquidity_mint: 0,
                        liquidity_burn: vault.total_liquidity_per_pool(i.into()).try_into().unwrap(),
                        pool_key: pool.pool_key,
                        new_bounds: pool.bounds,
                    },
                );
            i += 1;
        };
        vault.rebalance_pool(RebalanceParams { rebal: ins, swap_params: swap });
    }

    // On main this does NOT panic: the relayer burns 100%, swaps every xSTRK into its own pool
    // at ~1e-4 STRK/xSTRK with min_out = 1 (oracle check skipped) and keeps the proceeds.
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('Swap:: Slippage too high',))]
    fn test_c1_relayer_cannot_drain_via_own_pool() {
        let vault = setup_live_vault();
        let (_attacker_nft, _) = setup_attacker_pool();
        let value_before = vault_value_in_token1(vault);

        // compute vault's xSTRK after burn: positions amount0 + idle
        let pos = vault.get_positions();
        let x_total = pos.total_amount0 + bal(xstrk(), vault.contract_address);
        // leave 1% margin for withdrawal-fee rounding
        burn_all_and_swap(vault, drain_swap(vault, x_total * 99 / 100, 1));

        let value_after = vault_value_in_token1(vault);
        println!(
            "C1: vault value (STRK units) before={} after={} lost={}",
            value_before,
            value_after,
            value_before - value_after,
        );
        // reaching here means the drain succeeded
        assert(value_after * 100 >= value_before * 99, 'C1: vault drained');
    }

    // Swap into a token that is neither token0 nor token1 must be rejected.
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('invalid swap tokens',))]
    fn test_c1_swap_to_foreign_token_rejected() {
        let vault = setup_live_vault();
        let mut swap = empty_swap(vault);
        swap.token_to_address = constants::USDC_ADDRESS();
        swap.token_from_amount = E18;
        burn_all_and_swap(vault, swap);
    }

    // ============================================================================
    // H3: emptied pool must not brick withdraw; fees must be collected before burn
    // ============================================================================

    #[test]
    #[fork("mainnet_4707139")]
    fn test_h3_withdraw_after_pool_emptied() {
        let vault = two_pool_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        fund(alice, 100 * E18);
        let shares = deposit_as(vault, alice, 10 * E18, 10 * E18, 10 * E18);
        rebalance_max(vault);

        // relayer fully empties pool 1 (nft_id -> 0), pool 0 untouched
        let pools = vault.get_managed_pools();
        let p0 = *pools.at(0);
        let p1 = *pools.at(1);
        let ins = array![
            RangeInstruction {
                liquidity_mint: 0, liquidity_burn: 0, pool_key: p0.pool_key, new_bounds: p0.bounds,
            },
            RangeInstruction {
                liquidity_mint: 0,
                liquidity_burn: vault.total_liquidity_per_pool(1).try_into().unwrap(),
                pool_key: p1.pool_key,
                new_bounds: p1.bounds,
            },
        ];
        vault.rebalance_pool(RebalanceParams { rebal: ins, swap_params: empty_swap(vault) });
        assert(vault.total_liquidity_per_pool(1) == 0, 'setup: pool 1 not empty');

        // alice must still be able to exit
        let a0 = bal(xstrk(), alice);
        let a1 = bal(strk(), alice);
        start_cheat_caller_address(vault.contract_address, alice);
        vault.withdraw(shares / 2, alice);
        stop_cheat_caller_address(vault.contract_address);
        assert(bal(xstrk(), alice) > a0 || bal(strk(), alice) > a1, 'H3: nothing withdrawn');
    }

    // Also covers the "deposit then withdraw before first rebalance" path (all nft_id == 0).
    #[test]
    #[fork("mainnet_4707139")]
    fn test_h3_withdraw_before_first_rebalance() {
        let vault = single_pool_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        fund(alice, 100 * E18);
        let shares = deposit_as(vault, alice, 10 * E18, 10 * E18, 10 * E18);
        start_cheat_caller_address(vault.contract_address, alice);
        vault.withdraw(shares, alice);
        stop_cheat_caller_address(vault.contract_address);
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_h3_rebalance_collects_fees_before_burn() {
        let vault = setup_live_vault();
        let pool = vault.get_managed_pool(0);
        let old_nft = pool.nft_id;

        // generate fees: round-trip swaps through the vault's pool
        let this = get_contract_address();
        fund(this, 2000 * E18);
        let mut k = 0;
        while k != 4_u32 {
            avnu_swap_self(strk(), xstrk(), 500 * E18, pool.pool_key);
            avnu_swap_self(xstrk(), strk(), 400 * E18, pool.pool_key);
            k += 1;
        };
        let positions = IEkuboDispatcher { contract_address: constants::EKUBO_POSITIONS() };
        let info = positions.get_token_info(old_nft, pool.pool_key, pool.bounds);
        println!("H3: accrued fees before burn fee0={} fee1={}", info.fees0, info.fees1);
        assert(info.fees0 > 0 || info.fees1 > 0, 'setup: no fees accrued');

        burn_all_and_swap(vault, empty_swap(vault));

        let after = positions.get_token_info(old_nft, pool.pool_key, pool.bounds);
        println!("H3: fees left in old NFT after burn fee0={} fee1={}", after.fees0, after.fees1);
        assert(after.fees0 == 0 && after.fees1 == 0, 'H3: fees orphaned in old NFT');
    }
}
