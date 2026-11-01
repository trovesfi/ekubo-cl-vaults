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
        RebalanceParams, RangeInstruction, RebalanceSettings,
    };
    use snforge_std::{start_cheat_block_timestamp};
    use starkware_utils::components::pausable::interface::{IPausableDispatcher as ICommonDispatcher, IPausableDispatcherTrait as ICommonDispatcherTrait};
    use snforge_std::{
        declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address,
        stop_cheat_caller_address,
    };
    use starknet::{ContractAddress, get_contract_address};
    use troves_clvaults::helpers::{constants, ERC20Helper, pow};
    use troves_clvaults::components::swap::{
        AvnuMultiRouteSwap, Route, IAvnuDispatcher, IAvnuDispatcherTrait,
    };
    use troves_clvaults::interfaces::IEkuboCore::{Bounds, PoolKey};
    use troves_clvaults::interfaces::IEkuboPosition::{IEkuboDispatcher, IEkuboDispatcherTrait};
    use troves_clvaults::ekubo::types::i129::i129;
    use troves_clvaults::ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use troves_clvaults::ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
    use troves_clvaults::interfaces::IEkuboCore::PoolKey as EkPoolKey;
    use troves_clvaults::interfaces::IEkuboCore::Bounds as EkBounds;
    use openzeppelin::utils::serde::SerializedAppend;
    use troves_clvaults::tests::utils as test_utils;
    use openzeppelin::interfaces::timelock::{ITimelockDispatcher, ITimelockDispatcherTrait};
    use starkware_delayed_executor::delayed_executor::{
        IDelayedExecutorDispatcher, IDelayedExecutorDispatcherTrait,
    };
    use starkware_utils::components::roles::interface::{IRolesDispatcher, IRolesDispatcherTrait};
    use starkware_utils::components::replaceability::interface::{
        IReplaceableDispatcher, IReplaceableDispatcherTrait, ImplementationData,
    };
    use troves_clvaults::tests::mocks::{
        IMockReentrantDistributorDispatcher, IMockReentrantDistributorDispatcherTrait,
        IMockVesuOracleDispatcher, IMockVesuOracleDispatcherTrait,
    };
    use troves_clvaults::interfaces::IVesuOracle::{IVesuOracleDispatcher, IVesuOracleDispatcherTrait};

    pub const E18: u256 = 1_000_000_000_000_000_000;

    // ---------------------------------------------------------------- setup helpers

    pub fn xstrk() -> ContractAddress {
        constants::XSTRK_ADDRESS()
    }
    pub fn strk() -> ContractAddress {
        constants::STRK_ADDRESS()
    }

    pub fn pool_key_1() -> PoolKey {
        PoolKey {
            token0: xstrk(),
            token1: strk(),
            fee: 34028236692093847977029636859101184, // 0.01%
            tick_spacing: 200,
            extension: 0.try_into().unwrap(),
        }
    }

    pub fn pool_key_2() -> PoolKey {
        PoolKey {
            token0: xstrk(),
            token1: strk(),
            fee: 170141183460469235273462165868118016, // 0.05%
            tick_spacing: 1000,
            extension: 0.try_into().unwrap(),
        }
    }

    pub fn bounds_1() -> Bounds {
        Bounds { lower: i129 { mag: 104000, sign: false }, upper: i129 { mag: 124000, sign: false } }
    }

    pub fn bounds_2() -> Bounds {
        Bounds { lower: i129 { mag: 100000, sign: false }, upper: i129 { mag: 130000, sign: false } }
    }

    pub fn deploy_vault(pools: Array<ManagedPool>) -> IClVaultDispatcher {
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
        calldata.append(get_contract_address().into());
        calldata.append(constants::EKUBO_POSITIONS().into());
        calldata.append(constants::EKUBO_POSITIONS_NFT().into());
        calldata.append(constants::EKUBO_CORE().into());
        calldata.append(test_utils::VESU_ORACLE().into());
        fee_settings.serialize(ref calldata);
        init_values.serialize(ref calldata);
        pools.serialize(ref calldata);
        calldata.append(test_utils::TEST_TIMELOCK_DELAY.into());
        test_utils::test_timelock_classes().serialize(ref calldata);
        let (address, _) = cls.deploy(@calldata).expect('ClVault deploy failed');
        test_utils::setup_roles(address);
        test_utils::mock_timelock(test_utils::TEST_TIMELOCK_DELAY);
        IClVaultDispatcher { contract_address: address }
    }

    pub fn single_pool_vault() -> IClVaultDispatcher {
        deploy_vault(array![ManagedPool { pool_key: pool_key_1(), bounds: bounds_1(), nft_id: 0 }])
    }

    pub fn two_pool_vault() -> IClVaultDispatcher {
        deploy_vault(
            array![
                ManagedPool { pool_key: pool_key_1(), bounds: bounds_1(), nft_id: 0 },
                ManagedPool { pool_key: pool_key_2(), bounds: bounds_2(), nft_id: 0 },
            ],
        )
    }

    // whale = Ekubo core (holds plenty of both tokens on the fork)
    pub fn fund(user: ContractAddress, amount: u256) {
        let whale = constants::EKUBO_CORE();
        start_cheat_caller_address(strk(), whale);
        ERC20Helper::transfer(strk(), user, amount);
        stop_cheat_caller_address(strk());
        start_cheat_caller_address(xstrk(), whale);
        ERC20Helper::transfer(xstrk(), user, amount);
        stop_cheat_caller_address(xstrk());
    }

    pub fn approve_as(user: ContractAddress, token: ContractAddress, spender: ContractAddress, amt: u256) {
        start_cheat_caller_address(token, user);
        ERC20Helper::approve(token, spender, amt);
        stop_cheat_caller_address(token);
    }

    pub fn bal(token: ContractAddress, who: ContractAddress) -> u256 {
        ERC20Helper::balanceOf(token, who)
    }

    pub fn deposit_as(
        vault: IClVaultDispatcher, user: ContractAddress, a0: u256, a1: u256, allowance: u256,
    ) -> u256 {
        approve_as(user, xstrk(), vault.contract_address, allowance);
        approve_as(user, strk(), vault.contract_address, allowance);
        start_cheat_caller_address(vault.contract_address, user);
        let shares = vault.deposit(a0, a1, user);
        stop_cheat_caller_address(vault.contract_address);
        shares
    }

    pub fn empty_swap(vault: IClVaultDispatcher) -> AvnuMultiRouteSwap {
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
    pub fn rebalance_max(vault: IClVaultDispatcher) {
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
    pub fn vault_value_in_token1(vault: IClVaultDispatcher) -> u256 {
        let positions = vault.get_positions();
        let idle0 = bal(xstrk(), vault.contract_address);
        let idle1 = bal(strk(), vault.contract_address);
        let a0 = positions.total_amount0 + idle0;
        let a1 = positions.total_amount1 + idle1;
        // xSTRK ~ 1.1-1.2 STRK on this fork; 1.1 is enough for a loss-magnitude check
        a1 + a0 * 11 / 10
    }

    // Direct AVNU swap from the test contract (used to generate LP fees).
    pub fn avnu_swap_self(from: ContractAddress, to: ContractAddress, amount: u256, key: PoolKey) {
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

    pub fn setup_live_vault() -> IClVaultDispatcher {
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
    pub fn attacker_pool_key() -> EkPoolKey {
        EkPoolKey {
            token0: xstrk(),
            token1: strk(),
            fee: 0,
            tick_spacing: 999,
            extension: 0.try_into().unwrap(),
        }
    }

    pub fn setup_attacker_pool() -> (u64, EkBounds) {
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

    pub fn drain_swap(vault: IClVaultDispatcher, amount: u256, min_out: u256) -> AvnuMultiRouteSwap {
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

    pub fn drain_swap_via(vault: IClVaultDispatcher, key: PoolKey, amount: u256) -> AvnuMultiRouteSwap {
        let params: Array<felt252> = array![
            key.token0.into(), key.token1.into(), key.fee.into(), key.tick_spacing.into(),
            key.extension.into(), 10000000000000000000000000000000000000000000000000000000000000000000000,
        ];
        AvnuMultiRouteSwap {
            token_from_address: xstrk(),
            token_from_amount: amount,
            token_to_address: strk(),
            token_to_amount: 0,
            token_to_min_amount: 0,
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

    pub fn burn_all_and_swap(vault: IClVaultDispatcher, swap: AvnuMultiRouteSwap) {
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

    // ============================================================================
    // Withdraw (H4): not pausable, min-out, balance deltas == reported amounts
    // ============================================================================

    #[test]
    #[fork("mainnet_4707139")]
    fn test_withdraw_works_when_paused() {
        let vault = setup_live_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        ICommonDispatcher { contract_address: vault.contract_address }.pause();
        let shares = bal(vault.contract_address, alice);
        let a0 = bal(xstrk(), alice);
        let a1 = bal(strk(), alice);
        start_cheat_caller_address(vault.contract_address, alice);
        let out = vault.withdraw(shares, alice);
        stop_cheat_caller_address(vault.contract_address);
        assert(bal(xstrk(), alice) - a0 == out.total_amount0, 'amount0 mismatch');
        assert(bal(strk(), alice) - a1 == out.total_amount1, 'amount1 mismatch');
        assert(out.total_amount0 + out.total_amount1 > 0, 'nothing withdrawn');
        assert(bal(vault.contract_address, alice) == 0, 'shares not burned');
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('insufficient amount0',))]
    fn test_withdraw_with_min_enforced() {
        let vault = setup_live_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        let shares = bal(vault.contract_address, alice);
        let quote = vault.convert_to_assets(shares);
        start_cheat_caller_address(vault.contract_address, alice);
        vault.withdraw_with_min(shares, alice, quote.total_amount0 + 1, 0);
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_withdraw_with_min_ok() {
        let vault = setup_live_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        let shares = bal(vault.contract_address, alice) / 3;
        let quote = vault.convert_to_assets(shares);
        start_cheat_caller_address(vault.contract_address, alice);
        // 0.1% tolerance for the Ekubo withdrawal fee / rounding
        let out = vault
            .withdraw_with_min(
                shares, alice, quote.total_amount0 * 999 / 1000, quote.total_amount1 * 999 / 1000,
            );
        stop_cheat_caller_address(vault.contract_address);
        assert(out.total_amount0 > 0 || out.total_amount1 > 0, 'nothing withdrawn');
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('zero shares',))]
    fn test_withdraw_zero_shares() {
        let vault = setup_live_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        start_cheat_caller_address(vault.contract_address, alice);
        vault.withdraw(0, alice);
    }

    // ============================================================================
    // Rebalance guard-rails (C1, H1, H2)
    // ============================================================================

    pub fn settings_with(
        vault: IClVaultDispatcher,
        slippage: u32,
        pool_dev: u128,
        bounds_dist: u128,
        interval: u64,
        max0: u256,
        max1: u256,
    ) {
        vault
            .set_rebalance_settings(
                RebalanceSettings {
                    max_slippage_bps: slippage,
                    max_pool_tick_deviation: pool_dev,
                    max_bounds_distance: bounds_dist,
                    min_rebalance_interval: interval,
                    max_swap_amount0: max0,
                    max_swap_amount1: max1,
                },
            );
    }

    pub fn move_bounds(vault: IClVaultDispatcher, new_bounds: Bounds, burn_all: bool) {
        let pool = vault.get_managed_pool(0);
        let liq: u128 = vault.total_liquidity_per_pool(0).try_into().unwrap();
        let ins = array![
            RangeInstruction {
                liquidity_mint: liq / 2,
                liquidity_burn: if burn_all { liq } else { liq / 2 },
                pool_key: pool.pool_key,
                new_bounds,
            },
        ];
        vault.rebalance_pool(RebalanceParams { rebal: ins, swap_params: empty_swap(vault) });
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('PAUSED',))]
    fn test_rebalance_paused() {
        let vault = setup_live_vault();
        ICommonDispatcher { contract_address: vault.contract_address }.pause();
        rebalance_max(vault);
    }
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('slippage bps too high',))]
    fn test_rebalance_settings_slippage_cap() {
        let vault = single_pool_vault();
        settings_with(vault, 10001, 10000, 300000, 0, 1, 1);
    }
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: "ONLY_APP_GOVERNOR")]
    fn test_rebalance_settings_governor_only() {
        let vault = single_pool_vault();
        start_cheat_caller_address(vault.contract_address, 0xBAD.try_into().unwrap());
        settings_with(vault, 100, 10000, 300000, 0, 1, 1);
    }
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('rebalance too soon',))]
    fn test_rebalance_min_interval() {
        let vault = single_pool_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        fund(alice, 100 * E18);
        deposit_as(vault, alice, 10 * E18, 10 * E18, 10 * E18);
        settings_with(vault, 100, 10000, 300000, 3600, E18 * 1000, E18 * 1000);
        start_cheat_block_timestamp(vault.contract_address, 1_800_000_000);
        rebalance_max(vault);
        start_cheat_block_timestamp(vault.contract_address, 1_800_000_000 + 3599);
        rebalance_max(vault);
    }
    #[test]
    #[fork("mainnet_4707139")]
    fn test_rebalance_min_interval_elapsed() {
        let vault = single_pool_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        fund(alice, 100 * E18);
        deposit_as(vault, alice, 10 * E18, 10 * E18, 10 * E18);
        settings_with(vault, 100, 10000, 300000, 3600, E18 * 1000, E18 * 1000);
        start_cheat_block_timestamp(vault.contract_address, 1_800_000_000);
        rebalance_max(vault);
        start_cheat_block_timestamp(vault.contract_address, 1_800_000_000 + 3600);
        rebalance_max(vault);
    }
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('swap amount too high',))]
    fn test_rebalance_swap_cap() {
        let vault = setup_live_vault();
        settings_with(vault, 100, 10000, 300000, 0, E18, E18);
        let mut swap = empty_swap(vault);
        swap.token_from_amount = 2 * E18;
        burn_all_and_swap(vault, swap);
    }
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('liquidity must be zero',))]
    fn test_bounds_change_requires_empty_range() {
        let vault = setup_live_vault();
        let new_bounds = Bounds {
            lower: i129 { mag: 106000, sign: false }, upper: i129 { mag: 122000, sign: false },
        };
        move_bounds(vault, new_bounds, false);
    }
    #[test]
    #[fork("mainnet_4707139")]
    fn test_bounds_change_ok_and_fees_collected() {
        let vault = setup_live_vault();
        let old_nft = vault.get_managed_pool(0).nft_id;
        let new_bounds = Bounds {
            lower: i129 { mag: 106000, sign: false }, upper: i129 { mag: 122000, sign: false },
        };
        move_bounds(vault, new_bounds, true);
        let pool = vault.get_managed_pool(0);
        assert(pool.bounds == new_bounds, 'bounds not updated');
        assert(pool.nft_id == old_nft, 'nft should be reused');
        assert(vault.total_liquidity_per_pool(0) > 0, 'no liquidity in new range');
    }
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('bounds not aligned',))]
    fn test_bounds_must_be_aligned() {
        let vault = setup_live_vault();
        let new_bounds = Bounds {
            lower: i129 { mag: 106001, sign: false }, upper: i129 { mag: 122000, sign: false },
        };
        move_bounds(vault, new_bounds, true);
    }
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('bounds too far from oracle',))]
    fn test_bounds_near_oracle() {
        let vault = setup_live_vault();
        // ~ 19.6M ticks away from the xSTRK/STRK oracle tick (~114k)
        let new_bounds = Bounds {
            lower: i129 { mag: 19600000, sign: false }, upper: i129 { mag: 19650000, sign: false },
        };
        move_bounds(vault, new_bounds, true);
    }
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('pool price off oracle',))]
    fn test_mint_rejected_when_pool_off_oracle() {
        let vault = single_pool_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        fund(alice, 100 * E18);
        deposit_as(vault, alice, 10 * E18, 10 * E18, 10 * E18);
        // pool tick (~110.1k) vs oracle tick (~114.2k) differ by ~4k ticks on this fork block
        settings_with(vault, 100, 1000, 300000, 0, E18 * 1000, E18 * 1000);
        rebalance_max(vault);
    }

    // ============================================================================
    // Harvest (H1)
    // ============================================================================

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('PAUSED',))]
    fn test_harvest_paused() {
        let vault = single_pool_vault();
        ICommonDispatcher { contract_address: vault.contract_address }.pause();
        let claim = troves_clvaults::interfaces::IEkuboDistributor::Claim {
            id: 0, claimee: vault.contract_address, amount: 0,
        };
        vault
            .harvest(
                constants::EKUBO_CORE(), claim, array![].span(), empty_swap(vault), empty_swap(vault),
            );
    }

    // ============================================================================
    // Reentrancy guard (H7)
    // ============================================================================

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('ReentrancyGuard: reentrant call',))]
    fn test_reentrancy_blocked() {
        let vault = setup_live_vault();
        let cls = declare("MockReentrantDistributor").unwrap().contract_class();
        let (mock, _) = cls.deploy(@array![]).unwrap();
        IMockReentrantDistributorDispatcher { contract_address: mock }
            .set_target(vault.contract_address, strk());
        let claim = troves_clvaults::interfaces::IEkuboDistributor::Claim {
            id: 0, claimee: vault.contract_address, amount: 1,
        };
        // non-empty proof so the vault calls distributor.claim(), which re-enters handle_fees
        vault.harvest(mock, claim, array![1].span(), empty_swap(vault), empty_swap(vault));
    }

    // ============================================================================
    // Fee cap (H6)
    // ============================================================================

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('invalid fee bps',))]
    fn test_fee_cap() {
        let vault = single_pool_vault();
        vault.set_settings(FeeSettings { fee_bps: 10001, fee_collector: constants::EKUBO_FEE_COLLECTOR() });
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_fee_at_cap_ok() {
        let vault = single_pool_vault();
        vault.set_settings(FeeSettings { fee_bps: 10000, fee_collector: constants::EKUBO_FEE_COLLECTOR() });
        assert(vault.get_fee_settings().fee_bps == 10000, 'fee not set');
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('invalid fee collector',))]
    fn test_fee_collector_nonzero() {
        let vault = single_pool_vault();
        vault.set_settings(FeeSettings { fee_bps: 1000, fee_collector: 0.try_into().unwrap() });
    }

    // ============================================================================
    // Oracle (Vesu v2 IOracle: staleness + min sources enforced by the oracle)
    // ============================================================================

    // mock oracle seeded with the live Vesu prices at the fork block
    pub fn mock_oracle(valid: bool) -> IMockVesuOracleDispatcher {
        let cls = declare("MockVesuOracle").unwrap().contract_class();
        let (addr, _) = cls.deploy(@array![]).unwrap();
        let mock = IMockVesuOracleDispatcher { contract_address: addr };
        let vesu = IVesuOracleDispatcher { contract_address: test_utils::VESU_ORACLE() };
        mock.set_price(xstrk(), vesu.price(xstrk()).value, valid);
        mock.set_price(strk(), vesu.price(strk()).value, valid);
        mock
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_vesu_oracle_prices_valid_on_fork() {
        let vesu = IVesuOracleDispatcher { contract_address: test_utils::VESU_ORACLE() };
        let px = vesu.price(xstrk());
        let ps = vesu.price(strk());
        println!("vesu oracle xSTRK={} STRK={}", px.value, ps.value);
        assert(px.is_valid && ps.is_valid, 'vesu prices invalid');
        // xSTRK priced via conversion rate: must be > STRK
        assert(px.value > ps.value, 'xSTRK <= STRK');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_set_oracle_ok() {
        let vault = single_pool_vault();
        let mock = mock_oracle(true);
        vault.set_oracle(mock.contract_address);
        assert(vault.get_pool_settings(0).oracle == mock.contract_address, 'oracle not set');
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('oracle price invalid',))]
    fn test_set_oracle_rejects_invalid() {
        let vault = single_pool_vault();
        vault.set_oracle(mock_oracle(false).contract_address);
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: "ONLY_APP_GOVERNOR")]
    fn test_set_oracle_governor_only() {
        let vault = single_pool_vault();
        let mock = mock_oracle(true);
        start_cheat_caller_address(vault.contract_address, 0xBAD.try_into().unwrap());
        vault.set_oracle(mock.contract_address);
    }

    // stale / low-source price (is_valid = false) must block minting
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('oracle price invalid',))]
    fn test_rebalance_blocked_on_invalid_oracle() {
        let vault = single_pool_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        fund(alice, 100 * E18);
        deposit_as(vault, alice, 10 * E18, 10 * E18, 10 * E18);
        let mock = mock_oracle(true);
        vault.set_oracle(mock.contract_address);
        mock.set_price(xstrk(), 1, false);
        rebalance_max(vault);
    }

    // stale price must also block swaps
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('oracle price invalid',))]
    fn test_swap_blocked_on_invalid_oracle() {
        let vault = setup_live_vault();
        let mock = mock_oracle(true);
        vault.set_oracle(mock.contract_address);
        mock.set_price(strk(), 1, false);
        let pos = vault.get_positions();
        let x_total = pos.total_amount0 + bal(xstrk(), vault.contract_address);
        // honest route through the vault's own pool; fails on the oracle read
        burn_all_and_swap(vault, drain_swap_via(vault, pool_key_1(), x_total / 10));
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_honest_rebalance_swap_ok() {
        let vault = setup_live_vault();
        let x_before = bal(xstrk(), vault.contract_address)
            + vault.get_positions().total_amount0;
        let s_before = bal(strk(), vault.contract_address) + vault.get_positions().total_amount1;
        // swap 1 xSTRK through the vault's own (deep) pool: within 1% of the oracle
        burn_all_and_swap(vault, drain_swap_via(vault, pool_key_1(), E18));
        let x_after = bal(xstrk(), vault.contract_address);
        let s_after = bal(strk(), vault.contract_address);
        println!("honest swap: xSTRK {} -> {}, STRK {} -> {}", x_before, x_after, s_before, s_after);
        assert(s_after > s_before, 'no STRK received');
    }

    // ============================================================================
    // Idle balances are part of the share price (M2) + min_shares + dead shares
    // ============================================================================

    pub fn withdraw_all_as(vault: IClVaultDispatcher, user: ContractAddress) -> (u256, u256) {
        let shares = bal(vault.contract_address, user);
        start_cheat_caller_address(vault.contract_address, user);
        let out = vault.withdraw(shares, user);
        stop_cheat_caller_address(vault.contract_address);
        (out.total_amount0, out.total_amount1)
    }

    // previously: deposit then withdraw before the first rebalance returned nothing
    #[test]
    #[fork("mainnet_4707139")]
    fn test_idle_withdraw_before_rebalance_returns_funds() {
        let vault = single_pool_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        fund(alice, 100 * E18);
        deposit_as(vault, alice, 10 * E18, 10 * E18, 10 * E18);
        let (a0, a1) = withdraw_all_as(vault, alice);
        println!("idle exit: got {} / {}", a0, a1);
        // everything except the dead-share dust (1000 / 7.5e18 of the vault)
        assert(a0 >= 10 * E18 - 10_000 && a1 >= 10 * E18 - 10_000, 'idle funds not returned');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_dead_shares_minted_to_vault() {
        let vault = single_pool_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        fund(alice, 100 * E18);
        let shares = deposit_as(vault, alice, 10 * E18, 10 * E18, 10 * E18);
        assert(bal(vault.contract_address, vault.contract_address) == 1000, 'dead shares');
        assert(bal(vault.contract_address, alice) == shares, 'user shares');
    }

    // deposit -> withdraw must never be profitable, and lose at most the Ekubo withdrawal fee
    #[test]
    #[fork("mainnet_4707139")]
    fn test_deposit_withdraw_roundtrip() {
        let vault = setup_live_vault();
        let bob: ContractAddress = 0xB0B.try_into().unwrap();
        fund(bob, 1000 * E18);
        let b0 = bal(xstrk(), bob);
        let b1 = bal(strk(), bob);
        deposit_as(vault, bob, 5 * E18, 5 * E18, 1000 * E18);
        let paid0 = b0 - bal(xstrk(), bob);
        let paid1 = b1 - bal(strk(), bob);
        let (got0, got1) = withdraw_all_as(vault, bob);
        println!("roundtrip: paid {} / {}, got {} / {}", paid0, paid1, got0, got1);
        assert(got0 <= paid0 && got1 <= paid1, 'roundtrip profitable');
        // pool fee tier 0.01%: allow 0.1%
        assert(got0 * 1000 >= paid0 * 999 && got1 * 1000 >= paid1 * 999, 'roundtrip loss too big');
    }

    // deposit while most funds are idle, then rebalance: no value transfer between users
    #[test]
    #[fork("mainnet_4707139")]
    fn test_deposit_before_rebalance_is_fair() {
        let vault = single_pool_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        let bob: ContractAddress = 0xB0B.try_into().unwrap();
        fund(alice, 100 * E18);
        fund(bob, 100 * E18);
        deposit_as(vault, alice, 10 * E18, 10 * E18, 10 * E18);
        let b0 = bal(xstrk(), bob);
        let b1 = bal(strk(), bob);
        deposit_as(vault, bob, 10 * E18, 10 * E18, 10 * E18);
        let paid0 = b0 - bal(xstrk(), bob);
        let paid1 = b1 - bal(strk(), bob);
        rebalance_max(vault);
        let (got0, got1) = withdraw_all_as(vault, bob);
        let paid = paid1 + paid0 * 11 / 10;
        let got = got1 + got0 * 11 / 10;
        println!("bob paid value {} got value {}", paid, got);
        assert(got <= paid, 'bob extracted value');
        assert(got * 1000 >= paid * 999, 'bob lost value');
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('insufficient shares minted',))]
    fn test_deposit_with_min_shares_enforced() {
        let vault = setup_live_vault();
        let bob: ContractAddress = 0xB0B.try_into().unwrap();
        fund(bob, 100 * E18);
        let quote = vault.convert_to_shares(E18, E18).shares;
        approve_as(bob, xstrk(), vault.contract_address, E18);
        approve_as(bob, strk(), vault.contract_address, E18);
        start_cheat_caller_address(vault.contract_address, bob);
        vault.deposit_with_min(E18, E18, bob, quote + 1);
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_deposit_with_min_shares_ok() {
        let vault = setup_live_vault();
        let bob: ContractAddress = 0xB0B.try_into().unwrap();
        fund(bob, 100 * E18);
        let quote = vault.convert_to_shares(E18, E18).shares;
        approve_as(bob, xstrk(), vault.contract_address, E18);
        approve_as(bob, strk(), vault.contract_address, E18);
        start_cheat_caller_address(vault.contract_address, bob);
        let shares = vault.deposit_with_min(E18, E18, bob, quote);
        assert(shares == quote, 'quote mismatch');
    }

    // classic first-depositor inflation: tiny first deposit + large donation.
    // Victim must still get (almost exactly) what they pay for.
    #[test]
    #[fork("mainnet_4707139")]
    fn test_inflation_attack_harmless() {
        let vault = single_pool_vault();
        let attacker: ContractAddress = 0xBAD.try_into().unwrap();
        let victim: ContractAddress = 0xB0B.try_into().unwrap();
        fund(attacker, 1000 * E18);
        fund(victim, 100 * E18);
        deposit_as(vault, attacker, 4000, 4000, 4000);
        // donate
        start_cheat_caller_address(xstrk(), attacker);
        ERC20Helper::transfer(xstrk(), vault.contract_address, 100 * E18);
        stop_cheat_caller_address(xstrk());
        start_cheat_caller_address(strk(), attacker);
        ERC20Helper::transfer(strk(), vault.contract_address, 100 * E18);
        stop_cheat_caller_address(strk());

        let v0 = bal(xstrk(), victim);
        let v1 = bal(strk(), victim);
        deposit_as(vault, victim, 10 * E18, 10 * E18, 10 * E18);
        let paid0 = v0 - bal(xstrk(), victim);
        let paid1 = v1 - bal(strk(), victim);
        let (got0, got1) = withdraw_all_as(vault, victim);
        println!("inflation: victim paid {}/{} got {}/{}", paid0, paid1, got0, got1);
        assert(got0 * 1000 >= paid0 * 999 && got1 * 1000 >= paid1 * 999, 'victim lost value');
    }

    // ============================================================================
    // Timelock guard on governor / admin calls
    // ============================================================================

    pub fn fee(bps: u256) -> FeeSettings {
        FeeSettings { fee_bps: bps, fee_collector: constants::EKUBO_FEE_COLLECTOR() }
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('timelock delay too short',))]
    fn test_governor_timelock_too_short() {
        let vault = single_pool_vault();
        test_utils::mock_timelock(test_utils::TEST_TIMELOCK_DELAY - 1);
        vault.set_settings(fee(500));
    }

    // a plain account (no get_min_delay entrypoint) cannot act as governor
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic]
    fn test_governor_must_be_contract_with_timelock_abi() {
        let vault = single_pool_vault();
        snforge_std::stop_mock_call(snforge_std::test_address(), selector!("get_min_delay"));
        vault.add_pool(ManagedPool { pool_key: pool_key_2(), bounds: bounds_2(), nft_id: 0 });
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_min_timelock_delay_update() {
        let vault = single_pool_vault();
        assert(vault.get_min_timelock_delay() == test_utils::TEST_TIMELOCK_DELAY, 'init delay');
        vault.set_min_timelock_delay(3600);
        assert(vault.get_min_timelock_delay() == 3600, 'delay not updated');
        // a 1h timelock is now enough
        test_utils::mock_timelock(3600);
        vault.set_settings(fee(500));
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('invalid min timelock delay',))]
    fn test_min_timelock_delay_nonzero() {
        let vault = single_pool_vault();
        vault.set_min_timelock_delay(0);
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_pause_needs_no_timelock() {
        let vault = single_pool_vault();
        snforge_std::stop_mock_call(snforge_std::test_address(), selector!("get_min_delay"));
        let common = ICommonDispatcher { contract_address: vault.contract_address };
        common.pause();
        assert(common.is_paused(), 'not paused');
        common.unpause();
    }

    pub fn impl_data() -> ImplementationData {
        let cls = *declare("ConcLiquidityVault").unwrap().contract_class().class_hash;
        ImplementationData { impl_hash: cls, eic_data: Option::None, final: false }
    }

    // upgrades are delayed in-contract (StarkWare Replaceability, delay = min_timelock_delay)
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: "NOT_ENABLED_YET")]
    fn test_upgrade_delay_enforced() {
        let vault = single_pool_vault();
        let up = IReplaceableDispatcher { contract_address: vault.contract_address };
        let data = impl_data();
        up.add_new_implementation(data);
        up.replace_to(data);
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_upgrade_after_delay_ok() {
        let vault = single_pool_vault();
        let up = IReplaceableDispatcher { contract_address: vault.contract_address };
        assert(up.get_upgrade_delay() == test_utils::TEST_TIMELOCK_DELAY, 'upgrade delay');
        let data = impl_data();
        start_cheat_block_timestamp(vault.contract_address, 1_800_000_000);
        up.add_new_implementation(data);
        start_cheat_block_timestamp(
            vault.contract_address, 1_800_000_000 + test_utils::TEST_TIMELOCK_DELAY,
        );
        up.replace_to(data);
        assert(vault.get_min_timelock_delay() == test_utils::TEST_TIMELOCK_DELAY, 'state lost');
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: "ONLY_UPGRADE_GOVERNOR")]
    fn test_upgrade_governor_only() {
        let vault = single_pool_vault();
        let data = impl_data();
        start_cheat_caller_address(vault.contract_address, 0xBAD.try_into().unwrap());
        IReplaceableDispatcher { contract_address: vault.contract_address }.add_new_implementation(data);
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: "ONLY_SECURITY_GOVERNOR")]
    fn test_unpause_security_governor_only() {
        let vault = single_pool_vault();
        let p = ICommonDispatcher { contract_address: vault.contract_address };
        p.pause();
        start_cheat_caller_address(vault.contract_address, 0xBAD.try_into().unwrap());
        p.unpause();
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('no v1 access control',))]
    fn test_v1_role_bootstrap_not_callable_on_v2() {
        let vault = single_pool_vault();
        // fresh v2 vaults have no v1 access control
        vault.initialize_roles_from_v1(get_contract_address(), 1);
    }

    // NB: constructor `min_timelock_delay > 0` is not unit-tested: snforge 0.54 aborts the
    // test on any constructor revert (not catchable via deploy() or deploy_syscall).

    // ============================================================================
    // Timelock class pinning
    // ============================================================================

    // a contract with a different class (the mock oracle) acting as governor
    pub fn foreign_governor(vault: IClVaultDispatcher) -> ContractAddress {
        let other = mock_oracle(true).contract_address;
        IRolesDispatcher { contract_address: vault.contract_address }.register_app_governor(other);
        other
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('timelock class not allowed',))]
    fn test_governor_class_not_allowed() {
        let vault = single_pool_vault();
        let other = foreign_governor(vault);
        snforge_std::start_mock_call(other, selector!("get_min_delay"), test_utils::TEST_TIMELOCK_DELAY);
        start_cheat_caller_address(vault.contract_address, other);
        vault.set_settings(fee(500));
    }

    // a StarkWare MultiExecutor-style timelock (get_execution_delay) once its class is allowed
    #[test]
    #[fork("mainnet_4707139")]
    fn test_allowed_class_with_custom_delay_getter() {
        let vault = single_pool_vault();
        let other = foreign_governor(vault);
        vault.set_timelock_class(snforge_std::get_class_hash(other), selector!("get_execution_delay"));
        snforge_std::start_mock_call(
            other, selector!("get_execution_delay"), test_utils::TEST_TIMELOCK_DELAY,
        );
        start_cheat_caller_address(vault.contract_address, other);
        vault.set_settings(fee(500));
        assert(vault.get_fee_settings().fee_bps == 500, 'fee not set');
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('would lock out caller',))]
    fn test_cannot_remove_own_timelock_class() {
        let vault = single_pool_vault();
        vault.set_timelock_class(snforge_std::get_class_hash(snforge_std::test_address()), 0);
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_remove_other_timelock_class() {
        let vault = single_pool_vault();
        let other = mock_oracle(true).contract_address;
        let cls = snforge_std::get_class_hash(other);
        vault.set_timelock_class(cls, selector!("get_min_delay"));
        assert(vault.get_timelock_class_selector(cls) == selector!("get_min_delay"), 'not allowed');
        vault.set_timelock_class(cls, 0);
        assert(vault.get_timelock_class_selector(cls) == 0, 'not removed');
    }

    // ============================================================================
    // Real timelocks as governor: OZ TimelockController and StarkWare MultiExecutor
    // ============================================================================

    pub fn set_fee_call(vault: IClVaultDispatcher, bps: u256) -> starknet::account::Call {
        let mut cd: Array<felt252> = array![];
        fee(bps).serialize(ref cd);
        starknet::account::Call { to: vault.contract_address, selector: selector!("set_settings"), calldata: cd.span() }
    }

    pub fn deploy_oz_timelock(min_delay: u64) -> ContractAddress {
        let this = get_contract_address();
        let cls = declare("TimelockController").unwrap().contract_class();
        let mut cd: Array<felt252> = array![];
        min_delay.serialize(ref cd);
        array![this].span().serialize(ref cd); // proposers
        array![this].span().serialize(ref cd); // executors
        let zero: ContractAddress = 0.try_into().unwrap();
        zero.serialize(ref cd); // no extra admin
        let (addr, _) = cls.deploy(@cd).unwrap();
        addr
    }

    pub fn deploy_multi_executor(delay: u64) -> ContractAddress {
        let this = get_contract_address();
        let cls = declare("MultiExecutor").unwrap().contract_class();
        let mut cd: Array<felt252> = array![];
        array![this].span().serialize(ref cd); // owners
        1_u32.serialize(ref cd); // quorum
        1_u32.serialize(ref cd); // delay start threshold
        86400_u64.serialize(ref cd); // owner acceptance delay
        delay.serialize(ref cd); // execution delay
        (delay + 86400_u64).serialize(ref cd); // expiration
        let (addr, _) = cls.deploy(@cd).unwrap();
        addr
    }

    // allow the timelock's class (via the mocked test governor) and make it APP_GOVERNOR
    pub fn enable_governor(vault: IClVaultDispatcher, gov: ContractAddress, delay_selector: felt252) {
        vault.set_timelock_class(snforge_std::get_class_hash(gov), delay_selector);
        IRolesDispatcher { contract_address: vault.contract_address }.register_app_governor(gov);
    }

    pub fn oz_schedule_and_execute(timelock: ContractAddress, call: starknet::account::Call, delay: u64) {
        let tl = ITimelockDispatcher { contract_address: timelock };
        start_cheat_block_timestamp(timelock, 1_800_000_000);
        tl.schedule(call, 0, 0, delay);
        start_cheat_block_timestamp(timelock, 1_800_000_000 + delay);
        tl.execute(call, 0, 0);
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_oz_timelock_governs() {
        let vault = single_pool_vault();
        let tl = deploy_oz_timelock(test_utils::TEST_TIMELOCK_DELAY);
        enable_governor(vault, tl, selector!("get_min_delay"));
        oz_schedule_and_execute(tl, set_fee_call(vault, 700), test_utils::TEST_TIMELOCK_DELAY);
        assert(vault.get_fee_settings().fee_bps == 700, 'fee not set via OZ timelock');
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('timelock delay too short',))]
    fn test_oz_timelock_with_short_delay_rejected() {
        let vault = single_pool_vault();
        let tl = deploy_oz_timelock(3600);
        enable_governor(vault, tl, selector!("get_min_delay"));
        oz_schedule_and_execute(tl, set_fee_call(vault, 700), 3600);
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_starkware_multi_executor_governs() {
        let vault = single_pool_vault();
        let ex = deploy_multi_executor(test_utils::TEST_TIMELOCK_DELAY);
        enable_governor(vault, ex, selector!("get_execution_delay"));
        let calls = array![set_fee_call(vault, 800)].span();
        let d = IDelayedExecutorDispatcher { contract_address: ex };
        start_cheat_block_timestamp(ex, 1_800_000_000);
        d.submit_calls(calls, 0);
        start_cheat_block_timestamp(ex, 1_800_000_000 + test_utils::TEST_TIMELOCK_DELAY);
        d.exec_calls(calls, 0);
        assert(vault.get_fee_settings().fee_bps == 800, 'fee not set via MultiExecutor');
    }

    // an OZ timelock is not accepted under the StarkWare delay getter (wrong selector)
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic]
    fn test_timelock_class_with_wrong_selector_fails() {
        let vault = single_pool_vault();
        let tl = deploy_oz_timelock(test_utils::TEST_TIMELOCK_DELAY);
        enable_governor(vault, tl, selector!("get_execution_delay"));
        oz_schedule_and_execute(tl, set_fee_call(vault, 700), test_utils::TEST_TIMELOCK_DELAY);
    }

    // ============================================================================
    // Review fixes
    // ============================================================================

    // a pool whose nft_id is not owned by the vault must be rejected (would mis-price shares and
    // brick withdraws through Ekubo's auth check)
    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('nft not owned by vault',))]
    fn test_add_pool_foreign_nft_rejected() {
        let vault = single_pool_vault();
        // NFT #1 exists and is owned by someone else
        vault.add_pool(ManagedPool { pool_key: pool_key_2(), bounds: bounds_2(), nft_id: 1 });
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_add_pool_own_nft_ok() {
        let vault = setup_live_vault();
        let own_nft = vault.get_managed_pool(0).nft_id;
        vault.add_pool(ManagedPool { pool_key: pool_key_2(), bounds: bounds_2(), nft_id: own_nft });
        assert(vault.get_managed_pools_len() == 2, 'pool not added');
    }

    // withdraw collects accrued fees into idle (also while paused) and never re-deposits
    #[test]
    #[fork("mainnet_4707139")]
    fn test_withdraw_collects_fees_while_paused() {
        let vault = setup_live_vault();
        let alice: ContractAddress = 0xA11CE.try_into().unwrap();
        let pool = vault.get_managed_pool(0);
        let this = get_contract_address();
        fund(this, 2000 * E18);
        avnu_swap_self(strk(), xstrk(), 500 * E18, pool.pool_key);
        avnu_swap_self(xstrk(), strk(), 400 * E18, pool.pool_key);
        let positions = IEkuboDispatcher { contract_address: constants::EKUBO_POSITIONS() };
        let before = positions.get_token_info(pool.nft_id, pool.pool_key, pool.bounds);
        assert(before.fees0 > 0 || before.fees1 > 0, 'setup: no fees');
        let liq_before = vault.total_liquidity_per_pool(0);
        ICommonDispatcher { contract_address: vault.contract_address }.pause();
        let shares = bal(vault.contract_address, alice);
        start_cheat_caller_address(vault.contract_address, alice);
        vault.withdraw(shares / 2, alice);
        stop_cheat_caller_address(vault.contract_address);
        let after = positions.get_token_info(pool.nft_id, pool.pool_key, pool.bounds);
        assert(after.fees0 == 0 && after.fees1 == 0, 'fees not collected');
        // only the user's liquidity left the range (no re-deposit of fees)
        assert(vault.total_liquidity_per_pool(0) < liq_before, 'liquidity not reduced');
    }

    fn accrue_fees(vault: IClVaultDispatcher) {
        let pool = vault.get_managed_pool(0);
        let this = get_contract_address();
        fund(this, 2000 * E18);
        avnu_swap_self(strk(), xstrk(), 500 * E18, pool.pool_key);
        avnu_swap_self(xstrk(), strk(), 400 * E18, pool.pool_key);
    }

    // handle_fees compounds only near the oracle price
    #[test]
    #[fork("mainnet_4707139")]
    fn test_handle_fees_compounds_near_oracle() {
        let vault = setup_live_vault();
        accrue_fees(vault);
        let liq = vault.total_liquidity_per_pool(0);
        vault.handle_fees(0);
        assert(vault.total_liquidity_per_pool(0) > liq, 'fees not compounded');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_handle_fees_keeps_idle_when_pool_off_oracle() {
        let vault = setup_live_vault();
        accrue_fees(vault);
        // pool tick is ~4k ticks off the oracle at this block: a 1000-tick band excludes it
        settings_with(vault, 100, 1000, 300000, 0, E18 * 1000, E18 * 1000);
        let liq = vault.total_liquidity_per_pool(0);
        let i0 = bal(xstrk(), vault.contract_address);
        let i1 = bal(strk(), vault.contract_address);
        vault.handle_fees(0);
        assert(vault.total_liquidity_per_pool(0) == liq, 'compounded off-oracle');
        assert(
            bal(xstrk(), vault.contract_address) > i0 || bal(strk(), vault.contract_address) > i1,
            'fees not collected',
        );
    }

    // an invalid oracle must not block handle_fees (fees stay idle)
    #[test]
    #[fork("mainnet_4707139")]
    fn test_handle_fees_with_invalid_oracle_keeps_idle() {
        let vault = setup_live_vault();
        accrue_fees(vault);
        let mock = mock_oracle(true);
        vault.set_oracle(mock.contract_address);
        mock.set_price(strk(), 1, false);
        let liq = vault.total_liquidity_per_pool(0);
        vault.handle_fees(0);
        assert(vault.total_liquidity_per_pool(0) == liq, 'compounded on invalid oracle');
    }
}
