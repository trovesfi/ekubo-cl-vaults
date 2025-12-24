#[cfg(test)]
pub mod test_cl_vault_final {
    use troves_clvaults::cl_vault::interface::{
        IClVaultDispatcher, IClVaultDispatcherTrait, FeeSettings, 
        InitValues, ManagedPool, RebalanceParams, RangeInstruction
    };
    use troves_clvaults::cl_vault::interface::MaxUnusedBalances;
    use snforge_std::{
        declare, ContractClassTrait, start_cheat_caller_address, stop_cheat_caller_address
    };
    use snforge_std::{DeclareResultTrait};
    use starknet::{ContractAddress, get_contract_address};
    use strkfarm_contracts::helpers::constants;
    use troves_clvaults::cl_vault::interface::ClSettings;
    use strkfarm_contracts::helpers::ERC20Helper;
    use troves_clvaults::interfaces::IEkuboCore::{
        IEkuboCoreDispatcher, IEkuboCoreDispatcherTrait, Bounds, PoolKey
    };
    use troves_clvaults::interfaces::IEkuboPositionsNFT::{
        IEkuboNFTDispatcher, IEkuboNFTDispatcherTrait
    };
    use ekubo::types::i129::{i129};
    use openzeppelin::utils::serde::SerializedAppend;
    use strkfarm_contracts::helpers::pow;
    use strkfarm_contracts::components::swap::{AvnuMultiRouteSwap, Route};
    use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
    use troves_clvaults::tests::utils as test_utils;
    use strkfarm_contracts::interfaces::common::{ICommonDispatcher, ICommonDispatcherTrait};

    // ============================================================================
    // POOL CONFIGURATION HELPERS
    // ============================================================================

    // xSTRK/STRK Pool Configurations (18 decimals each)
    fn get_pool_key_xstrk_strk_1() -> PoolKey {
        PoolKey {
            token0: constants::XSTRK_ADDRESS(),
            token1: constants::STRK_ADDRESS(),
            fee: 34028236692093847977029636859101184,
            tick_spacing: 200,
            extension: 0.try_into().unwrap()
        }
    }

    fn get_pool_key_xstrk_strk_2() -> PoolKey {
        let extension: ContractAddress = 0.try_into().unwrap();
        PoolKey {
            token0: constants::XSTRK_ADDRESS(),
            token1: constants::STRK_ADDRESS(),
            fee: 170141183460469235273462165868118016,
            tick_spacing: 1000,
            extension: extension
        }
    }

    // narrower bounds
    fn get_bounds_xstrk_strk_1() -> Bounds {
        Bounds {
            lower: i129 { mag: 104000, sign: false },
            upper: i129 { mag: 124000, sign: false }
        }
    }

    // wider bounds
    fn get_bounds_xstrk_strk_2() -> Bounds {
        Bounds {
            lower: i129 { mag: 114000, sign: true },
            upper: i129 { mag: 144000, sign: false }
        }
    }

    // out of range bounds
    fn get_bounds_xstrk_strk_3() -> Bounds {
        // Third bounds set for pool_key_xstrk_strk_1 (tick_spacing: 200)
        // Values are multiples of 200: 19590000 = 97950 * 200, 19626000 = 98130 * 200
        Bounds {
            lower: i129 { mag: 74000, sign: false },
            upper: i129 { mag: 94000, sign: false }
        }
    }

    // USDC/USDT Pool Configurations (6 decimals each)
    fn get_pool_key_usdc_usdt_1() -> PoolKey {
        let extension: ContractAddress = 0.try_into().unwrap();
        PoolKey {
            token0: constants::USDC_ADDRESS(),
            token1: constants::USDT_ADDRESS(),
            fee: 34028236692093847977029636859101184,
            tick_spacing: 200,
            extension: extension
        }
    }

    fn get_pool_key_usdc_usdt_2() -> PoolKey {
        let extension: ContractAddress = 0.try_into().unwrap();
        PoolKey {
            token0: constants::USDC_ADDRESS(),
            token1: constants::USDT_ADDRESS(),
            fee: 170141183460469235273462165868118016,
            tick_spacing: 1000,
            extension: extension
        }
    }

    fn get_bounds_usdc_usdt_1() -> Bounds {
        Bounds {
            lower: i129 { mag: 200, sign: true }, // -200
            upper: i129 { mag: 200, sign: false }
        }
    }

    fn get_bounds_usdc_usdt_2() -> Bounds {
        Bounds {
            lower: i129 { mag: 10000, sign: true }, // -10000
            upper: i129 { mag: 20000, sign: false }
        }
    }

    // ETH/USDC Pool Configurations (18 and 6 decimals)
    fn get_pool_key_eth_usdc_1() -> PoolKey {
        let extension: ContractAddress = 0.try_into().unwrap();
        PoolKey {
            token0: constants::ETH_ADDRESS(),
            token1: constants::USDC_ADDRESS(),
            fee: 170141183460469235273462165868118016,
            tick_spacing: 1000,
            extension: extension
        }
    }

    fn get_pool_key_eth_usdc_2() -> PoolKey {
        let extension: ContractAddress = 0.try_into().unwrap();
        PoolKey {
            token0: constants::ETH_ADDRESS(),
            token1: constants::USDC_ADDRESS(),
            fee: 34028236692093847977029636859101184,
            tick_spacing: 200,
            extension: extension
        }
    }

    fn get_bounds_eth_usdc_1() -> Bounds {
        Bounds {
            lower: i129 { mag: 19599000, sign: true },
            upper: i129 { mag: 19567000, sign: true }
        }
    }

    fn get_bounds_eth_usdc_2() -> Bounds {
        Bounds {
            lower: i129 { mag: 19589000, sign: true },
            upper: i129 { mag: 19577000, sign: true }
        }
    }

    // Pool creation helpers
    fn create_pool(pool_key: PoolKey, bounds: Bounds) -> ManagedPool {
        ManagedPool {
            pool_key: pool_key,
            bounds: bounds,
            nft_id: 0
        }
    }

    // Pool configuration builders
    fn get_pool_config_xstrk_strk() -> Array<ManagedPool> {
        let mut pools = ArrayTrait::<ManagedPool>::new();
        pools.append(create_pool(get_pool_key_xstrk_strk_1(), get_bounds_xstrk_strk_1()));
        pools.append(create_pool(get_pool_key_xstrk_strk_2(), get_bounds_xstrk_strk_2()));
        pools
    }

    fn get_pool_config_usdc_usdt() -> Array<ManagedPool> {
        let mut pools = ArrayTrait::<ManagedPool>::new();
        pools.append(create_pool(get_pool_key_usdc_usdt_1(), get_bounds_usdc_usdt_1()));
        pools.append(create_pool(get_pool_key_usdc_usdt_2(), get_bounds_usdc_usdt_2()));
        pools
    }

    fn get_pool_config_eth_usdc() -> Array<ManagedPool> {
        let mut pools = ArrayTrait::<ManagedPool>::new();
        pools.append(create_pool(get_pool_key_eth_usdc_1(), get_bounds_eth_usdc_1()));
        pools.append(create_pool(get_pool_key_eth_usdc_2(), get_bounds_eth_usdc_2()));
        pools
    }

    fn create_single_pool_config(pool_key: PoolKey, bounds: Bounds) -> Array<ManagedPool> {
        let mut pools = ArrayTrait::<ManagedPool>::new();
        pools.append(create_pool(pool_key, bounds));
        pools
    }

    fn create_two_pools_diff_keys(pool_key1: PoolKey, pool_key2: PoolKey, bounds: Bounds) -> Array<ManagedPool> {
        let mut pools = ArrayTrait::<ManagedPool>::new();
        pools.append(create_pool(pool_key1, bounds));
        pools.append(create_pool(pool_key2, bounds));
        pools
    }

    fn create_two_pools_diff_bounds(pool_key: PoolKey, bounds1: Bounds, bounds2: Bounds) -> Array<ManagedPool> {
        let mut pools = ArrayTrait::<ManagedPool>::new();
        pools.append(create_pool(pool_key, bounds1));
        pools.append(create_pool(pool_key, bounds2));
        pools
    }

    // ============================================================================
    // VAULT DEPLOYMENT HELPERS
    // ============================================================================

    fn deploy_vault_with_config(
        managed_pools: Array<ManagedPool>,
        init_values: InitValues
    ) -> (IClVaultDispatcher, ERC20ABIDispatcher) {
        let accessControl = test_utils::deploy_access_control();
        let clVault = declare("ConcLiquidityVault").unwrap().contract_class();
        
        let fee_bps = 1000;
        let name: ByteArray = "uCL_token";
        let symbol: ByteArray = "UCL";
        let fee_settings = FeeSettings {
            fee_bps: fee_bps,
            fee_collector: constants::EKUBO_FEE_COLLECTOR()
        };
        
        let mut calldata: Array<felt252> = array![];
        calldata.append_serde(name);
        calldata.append_serde(symbol);
        calldata.append(accessControl.into());
        calldata.append(constants::EKUBO_POSITIONS().into());
        calldata.append(constants::EKUBO_POSITIONS_NFT().into());
        calldata.append(constants::EKUBO_CORE().into());
        calldata.append(constants::ORACLE_OURS().into());
        fee_settings.serialize(ref calldata);
        init_values.serialize(ref calldata);
        managed_pools.serialize(ref calldata);
        
        let (address, _) = clVault.deploy(@calldata).expect('ClVault deploy failed');

        (
            IClVaultDispatcher { contract_address: address },
            ERC20ABIDispatcher { contract_address: address }
        )
    }

    fn deploy_vault_xstrk_strk() -> (IClVaultDispatcher, ERC20ABIDispatcher) {
        let managed_pools = get_pool_config_xstrk_strk();
        let init_values = InitValues {
            init0: pow::ten_pow(18),
            init1: 2 * pow::ten_pow(18)
        };
        deploy_vault_with_config(managed_pools, init_values)
    }

    fn deploy_vault_usdc_usdt() -> (IClVaultDispatcher, ERC20ABIDispatcher) {
        let managed_pools = get_pool_config_usdc_usdt();
        let init_values = InitValues {
            init0: pow::ten_pow(6),
            init1: pow::ten_pow(6)
        };
        deploy_vault_with_config(managed_pools, init_values)
    }

    fn deploy_vault_eth_usdc() -> (IClVaultDispatcher, ERC20ABIDispatcher) {
        let managed_pools = get_pool_config_eth_usdc();
        let init_values = InitValues {
            init0: pow::ten_pow(18),
            init1: 3000 * pow::ten_pow(6)
        };
        deploy_vault_with_config(managed_pools, init_values)
    }

    // ============================================================================
    // TOKEN INITIALIZATION HELPERS
    // ============================================================================

    fn init_tokens_xstrk_strk(amount: u256) {
        let ekubo_user = constants::EKUBO_CORE();
        let this = get_contract_address();

        start_cheat_caller_address(constants::STRK_ADDRESS(), ekubo_user);
        ERC20Helper::transfer(constants::STRK_ADDRESS(), this, amount);
        stop_cheat_caller_address(constants::STRK_ADDRESS());

        start_cheat_caller_address(constants::XSTRK_ADDRESS(), ekubo_user);
        ERC20Helper::transfer(constants::XSTRK_ADDRESS(), this, amount);
        stop_cheat_caller_address(constants::XSTRK_ADDRESS());
    }

    fn init_tokens_usdc_usdt(amount: u256) {
        let ekubo_user = constants::EKUBO_CORE();
        let this = get_contract_address();

        start_cheat_caller_address(constants::USDC_ADDRESS(), ekubo_user);
        ERC20Helper::transfer(constants::USDC_ADDRESS(), this, amount);
        stop_cheat_caller_address(constants::USDC_ADDRESS());

        start_cheat_caller_address(constants::USDT_ADDRESS(), ekubo_user);
        ERC20Helper::transfer(constants::USDT_ADDRESS(), this, amount);
        stop_cheat_caller_address(constants::USDT_ADDRESS());
    }

    fn init_tokens_eth_usdc(amount_eth: u256, amount_usdc: u256) {
        let ekubo_user = constants::EKUBO_CORE();
        let this = get_contract_address();

        start_cheat_caller_address(constants::ETH_ADDRESS(), ekubo_user);
        ERC20Helper::transfer(constants::ETH_ADDRESS(), this, amount_eth);
        stop_cheat_caller_address(constants::ETH_ADDRESS());

        start_cheat_caller_address(constants::USDC_ADDRESS(), ekubo_user);
        ERC20Helper::transfer(constants::USDC_ADDRESS(), this, amount_usdc);
        stop_cheat_caller_address(constants::USDC_ADDRESS());
    }

    // ============================================================================
    // TEST FLOW HELPERS
    // ============================================================================

    fn create_empty_swap_params(vault: IClVaultDispatcher) -> AvnuMultiRouteSwap {
        let pool = vault.get_managed_pool(0);
        let mut routes = ArrayTrait::<Route>::new();
        let integrator_fee_recipient: ContractAddress = 0.try_into().unwrap();
        AvnuMultiRouteSwap {
            token_from_address: pool.pool_key.token0,
            token_from_amount: 0,
            token_to_address: pool.pool_key.token1,
            token_to_amount: 0,
            token_to_min_amount: 0,
            beneficiary: vault.contract_address,
            integrator_fee_amount_bps: 0,
            integrator_fee_recipient: integrator_fee_recipient,
            routes
        }
    }

    fn create_rebalance_params(
        vault: IClVaultDispatcher,
        liquidity_amounts: Array<u256>
    ) -> RebalanceParams {
        let pools = vault.get_managed_pools();
        let mut range_ins = ArrayTrait::<RangeInstruction>::new();
        let mut i = 0;
        
        while i != pools.len() {
            let pool = *pools.at(i);
            let liq = *liquidity_amounts.at(i);
            let current_liq = vault.total_liquidity_per_pool(i.into());
            let ins = RangeInstruction {
                liquidity_mint: liq.try_into().unwrap(),
                liquidity_burn: if current_liq > 0 { current_liq.try_into().unwrap() } else { 0 },
                pool_key: pool.pool_key,
                new_bounds: pool.bounds
            };
            range_ins.append(ins);
            i += 1;
        }
        
        RebalanceParams {
            rebal: range_ins,
            swap_params: create_empty_swap_params(vault)
        }
    }

    // ============================================================================
    // PERMISSION TEST HELPERS
    // ============================================================================

    fn get_common_dispatcher(vault: IClVaultDispatcher) -> ICommonDispatcher {
        ICommonDispatcher { contract_address: vault.contract_address }
    }

    // ============================================================================
    // CATEGORY 1: BASIC FUNCTIONALITY TESTS
    // ============================================================================

    #[test]
    #[fork("mainnet_4707139")]
    fn test_constructor_xstrk_strk() {
        let (clVault, erc20Disp) = deploy_vault_xstrk_strk();
        let managed_pools = clVault.get_managed_pools();
        let expected_pools = get_pool_config_xstrk_strk();
        
        assert(managed_pools.len() == 2, 'should have 2 pools');
        assert(erc20Disp.name() == "uCL_token", 'invalid name');
        assert(erc20Disp.symbol() == "UCL", 'invalid symbol');
        assert(erc20Disp.decimals() == 18, 'invalid decimals');
        assert(erc20Disp.total_supply() == 0, 'invalid total supply');
        
        let mut i: u32 = 0;
        while i != managed_pools.len() {
            let settings: ClSettings = clVault.get_pool_settings(i.into());
            let expected_pool = *expected_pools.at(i);
            assert(settings.pool_key.fee == expected_pool.pool_key.fee, 'invalid pool fee');
            assert(settings.pool_key.tick_spacing == expected_pool.pool_key.tick_spacing, 'invalid tick spacing');
            assert(settings.bounds_settings.lower.mag == expected_pool.bounds.lower.mag, 'invalid bounds lower');
            assert(settings.bounds_settings.upper.mag == expected_pool.bounds.upper.mag, 'invalid bounds upper');
            assert(clVault.total_liquidity_per_pool(i.into()) == 0, 'invalid initial liquidity');
            i += 1;
        }
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_deposit_single_pool_xstrk_strk() {
        let this = get_contract_address();
        
        // Create single pool config
        let single_pool = create_single_pool_config(
            get_pool_key_xstrk_strk_1(),
            get_bounds_xstrk_strk_1()
        );
        let (clVault_single, _) = deploy_vault_with_config(
            single_pool,
            InitValues { init0: pow::ten_pow(18), init1: 2 * pow::ten_pow(18) }
        );
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault_single.contract_address, amount);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault_single.contract_address, amount);
        
        let shares = clVault_single.deposit(amount, amount, this);
        assert(shares > 0, 'invalid shares minted');
        
        let managed_pools = clVault_single.get_managed_pools();
        let mut i: u32 = 0;
        while i != managed_pools.len() {
            let settings = clVault_single.get_pool_settings(i.into());
            let nft_id: u64 = settings.contract_nft_id;
            assert(nft_id == 0, 'invalid nft id');
            i += 1;
        }

        // rebalance to add liquidity
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(5 * pow::ten_pow(18));
        let rebal_params = create_rebalance_params(clVault_single, liq_array);
        clVault_single.rebalance_pool(rebal_params);
       
        // assert nft is non-zero and owner is contract address
        let managed_pools = clVault_single.get_managed_pools();
        let mut i: u32 = 0;
        while i != managed_pools.len() {
            let settings = clVault_single.get_pool_settings(i.into());
            let nft_id: u64 = settings.contract_nft_id;
            assert(nft_id > 0, 'invalid nft id');
            let nft_disp = IEkuboNFTDispatcher { contract_address: settings.ekubo_positions_nft };
            assert(nft_disp.ownerOf(nft_id.into()) == clVault_single.contract_address, 'invalid owner');
            i += 1;
        }
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_deposit_single_pool_usdc_usdt() {
        let single_pool = create_single_pool_config(
            get_pool_key_usdc_usdt_1(),
            get_bounds_usdc_usdt_1()
        );
        let (clVault, _) = deploy_vault_with_config(
            single_pool,
            InitValues { init0: pow::ten_pow(6), init1: pow::ten_pow(6) }
        );
        
        let this = get_contract_address();
        let amount = 1000 * pow::ten_pow(6);
        init_tokens_usdc_usdt(amount * 2);
        
        ERC20Helper::approve(constants::USDC_ADDRESS(), clVault.contract_address, amount);
        ERC20Helper::approve(constants::USDT_ADDRESS(), clVault.contract_address, amount);
        
        let shares = clVault.deposit(amount, amount, this);
        assert(shares > 0, 'invalid shares minted');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_deposit_single_pool_eth_usdc() {
        let single_pool = create_single_pool_config(
            get_pool_key_eth_usdc_1(),
            get_bounds_eth_usdc_1()
        );
        let (clVault, _) = deploy_vault_with_config(
            single_pool,
            InitValues { init0: pow::ten_pow(18), init1: 3000 * pow::ten_pow(6) }
        );
        
        let this = get_contract_address();
        let amount_eth = pow::ten_pow(18);
        let amount_usdc = 2000 * pow::ten_pow(6);
        init_tokens_eth_usdc(amount_eth, amount_usdc);
        
        ERC20Helper::approve(constants::ETH_ADDRESS(), clVault.contract_address, amount_eth);
        ERC20Helper::approve(constants::USDC_ADDRESS(), clVault.contract_address, amount_usdc);
        
        let shares = clVault.deposit(amount_eth, amount_usdc, this);
        assert(shares > 0, 'invalid shares minted');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_deposit_two_pools_diff_keys() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let shares = clVault.deposit(amount, amount, this);
        assert(shares > 0, 'invalid shares minted');
        
        // Rebalance to add liquidity - use very small amounts
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(5 * pow::ten_pow(18));
        liq_array.append(2 * pow::ten_pow(18));
        let rebal_params = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params);
        
        let pools = clVault.get_managed_pools();
        assert(pools.len() == 2, 'should have 2 pools');
        
        // Verify liquidity is distributed
        let mut i: u32 = 0;
        while i != pools.len() {
            let position = clVault.get_position(i.into());
            assert(position.liquidity > 0 || position.amount0 > 0 || position.amount1 > 0, 'pool should have liquidity');
            i += 1;
        }
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_deposit_two_pools_diff_bounds() {
        let pools = create_two_pools_diff_bounds(
            get_pool_key_xstrk_strk_1(),
            get_bounds_xstrk_strk_1(),
            get_bounds_xstrk_strk_2()
        );
        let (clVault, _) = deploy_vault_with_config(
            pools,
            InitValues { init0: pow::ten_pow(18), init1: 2 * pow::ten_pow(18) }
        );
        
        let this = get_contract_address();
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let shares = clVault.deposit(amount, amount, this);
        assert(shares > 0, 'invalid shares minted');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_withdraw_partial() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        
        // Rebalance to add liquidity - use very small amounts
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(5 * pow::ten_pow(18));
        liq_array.append(2 * pow::ten_pow(18));
        let rebal_params = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params);

        let total_shares = ERC20Helper::balanceOf(clVault.contract_address, this);
        let strk_before = ERC20Helper::balanceOf(constants::STRK_ADDRESS(), this);
        let xstrk_before = ERC20Helper::balanceOf(constants::XSTRK_ADDRESS(), this);
        
        let withdraw_amount = total_shares / 2;
        clVault.withdraw(withdraw_amount, this);

        let shares_after = ERC20Helper::balanceOf(clVault.contract_address, this);
        assert(shares_after == (total_shares - withdraw_amount), 'shares not burned correctly');
        
        let strk_after = ERC20Helper::balanceOf(constants::STRK_ADDRESS(), this);
        let xstrk_after = ERC20Helper::balanceOf(constants::XSTRK_ADDRESS(), this);
        assert(strk_after > strk_before, 'STRK not withdrawn');
        assert(xstrk_after > xstrk_before, 'xSTRK not withdrawn');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_withdraw_full() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        let total_shares = ERC20Helper::balanceOf(clVault.contract_address, this);
        
        clVault.withdraw(total_shares, this);
        
        let shares_after = ERC20Helper::balanceOf(clVault.contract_address, this);
        assert(shares_after / 10 == 0, 'shares should be zero');
        
        // Verify liquidity is drained
        let mut i: u32 = 0;
        let pools = clVault.get_managed_pools();
        while i != pools.len() {
            let liquidity = clVault.total_liquidity_per_pool(i.into());
            assert(liquidity / 10000 == 0, 'liquidity should be zero');
            i += 1;
        }
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_withdraw_after_rebalance() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        
        // Use very small liquidity amounts that fit within deposited tokens
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(5 * pow::ten_pow(18));
        liq_array.append(2 * pow::ten_pow(18));
        let rebal_params = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params);
        
        // Withdraw after rebalance
        let total_shares = ERC20Helper::balanceOf(clVault.contract_address, this);
        let strk_before = ERC20Helper::balanceOf(constants::STRK_ADDRESS(), this);
        let xstrk_before = ERC20Helper::balanceOf(constants::XSTRK_ADDRESS(), this);
        
        clVault.withdraw(total_shares / 2, this);
        
        let strk_after = ERC20Helper::balanceOf(constants::STRK_ADDRESS(), this);
        let xstrk_after = ERC20Helper::balanceOf(constants::XSTRK_ADDRESS(), this);
        assert(strk_after > strk_before, 'STRK should be withdrawn');
        assert(xstrk_after > xstrk_before, 'xSTRK should be withdrawn');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_rebalance_single_pool() {
        let single_pool = create_single_pool_config(
            get_pool_key_xstrk_strk_1(),
            get_bounds_xstrk_strk_1()
        );
        let (clVault, _) = deploy_vault_with_config(
            single_pool,
            InitValues { init0: pow::ten_pow(18), init1: 2 * pow::ten_pow(18) }
        );
        
        let this = get_contract_address();
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        
        // First rebalance to add initial liquidity
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(5 * pow::ten_pow(18));
        let rebal_params = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params);
        
        let liquidity_before = clVault.total_liquidity_per_pool(0);
        
        // Second deposit and rebalance to increase liquidity
        init_tokens_xstrk_strk(amount * 2);
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        let _shares2 = clVault.deposit(amount, amount, this);
        
        let mut liq_array2 = ArrayTrait::<u256>::new();
        liq_array2.append(10 * pow::ten_pow(18));
        let rebal_params2 = create_rebalance_params(clVault, liq_array2);
        clVault.rebalance_pool(rebal_params2);
        
        let liquidity_after = clVault.total_liquidity_per_pool(0);
        assert(liquidity_after > liquidity_before, 'liquidity should increase');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_rebalance_multiple_pools() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        
        // Use very small liquidity amounts that fit within available tokens
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(5 * pow::ten_pow(18));
        liq_array.append(2 * pow::ten_pow(18));
        
        let rebal_params = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params);
        
        let liq0 = clVault.total_liquidity_per_pool(0);
        let liq1 = clVault.total_liquidity_per_pool(1);
        assert(liq0 > 0, 'pool 0 should have liquidity');
        assert(liq1 > 0, 'pool 1 should have liquidity');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_rebalance_change_bounds() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        
        // First rebalance to add initial liquidity - use very small amounts
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(5 * pow::ten_pow(18));
        liq_array.append(2 * pow::ten_pow(18));
        let rebal_params = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params);
        
        // Get current bounds
        let pool0 = clVault.get_managed_pool(0);
        let _old_bounds = pool0.bounds;
        
        // Create new bounds
        let new_bounds = Bounds {
            lower: i129 { mag: 19600000, sign: false },
            upper: i129 { mag: 19650000, sign: false }
        };
        
        // Rebalance with new bounds - burn existing and mint same amount
        let pools = clVault.get_managed_pools();
        let mut range_ins = ArrayTrait::<RangeInstruction>::new();
        let mut i = 0;
        while i != pools.len() {
            let pool = *pools.at(i);
            let current_liq = clVault.total_liquidity_per_pool(i.into());
            let ins = RangeInstruction {
                liquidity_mint: current_liq.try_into().unwrap(),
                liquidity_burn: current_liq.try_into().unwrap(),
                pool_key: pool.pool_key,
                new_bounds: if i == 0 { new_bounds } else { pool.bounds }
            };
            range_ins.append(ins);
            i += 1;
        }
        
        let rebal_params2 = RebalanceParams {
            rebal: range_ins,
            swap_params: create_empty_swap_params(clVault)
        };
        clVault.rebalance_pool(rebal_params2);
        
        // Verify bounds changed
        let updated_pool = clVault.get_managed_pool(0);
        assert(updated_pool.bounds.lower.mag == new_bounds.lower.mag, 'bounds should be updated');
        assert(updated_pool.bounds.upper.mag == new_bounds.upper.mag, 'bounds should be updated');
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: "Rebalance: excessive unused token0")]
    fn test_rebalance_excessive_unused_token0() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        
        // Set max_unused_token0 to a very low value that will be exceeded
        // This should panic because we're leaving most tokens unused
        let max_unused_balances = MaxUnusedBalances {
            token0: 1 * pow::ten_pow(15), // 0.001 tokens
            token1: 0 // Skip check for token1
        };
        // Use local trait to call the method
        let local_vault = troves_clvaults::cl_vault::interface::IClVaultDispatcher {
            contract_address: clVault.contract_address
        };
        local_vault.set_max_unused_balances_on_rebalance(max_unused_balances);
        
        // Rebalance with very small liquidity amounts to intentionally leave unused tokens
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(1 * pow::ten_pow(18)); // Very small, will leave most tokens unused
        liq_array.append(1 * pow::ten_pow(18));
        
        let rebal_params = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params);
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: "Rebalance: excessive unused token1")]
    fn test_rebalance_excessive_unused_token1() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        
        // Set max_unused_token1 to a very low value that will be exceeded
        // This should panic because we're leaving most tokens unused
        let max_unused_balances = MaxUnusedBalances {
            token0: 0, // Skip check for token0
            token1: 1 * pow::ten_pow(15) // 0.001 tokens
        };
        // Use local trait to call the method
        let local_vault = troves_clvaults::cl_vault::interface::IClVaultDispatcher {
            contract_address: clVault.contract_address
        };
        local_vault.set_max_unused_balances_on_rebalance(max_unused_balances);
        
        // Rebalance with very small liquidity amounts to intentionally leave unused tokens
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(1 * pow::ten_pow(18)); // Very small, will leave most tokens unused
        liq_array.append(1 * pow::ten_pow(18));
        
        let rebal_params = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params);
    }

    // ============================================================================
    // CATEGORY 2: POOL MANAGEMENT TESTS
    // ============================================================================

    #[test]
    #[fork("mainnet_4707139")]
    fn test_add_pool_after_deployment() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let pools_before = clVault.get_managed_pools();
        assert(pools_before.len() == 2, 'should start with 2 pools');
        
        // Create a third pool with different bounds
        let new_pool = create_pool(
            get_pool_key_xstrk_strk_1(),
            get_bounds_xstrk_strk_2()
        );
        
        clVault.add_pool(new_pool);
        
        let pools_after = clVault.get_managed_pools();
        assert(pools_after.len() == 3, 'should have 3 pools');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_add_pool_deposit_rebalance() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        // Add third pool
        let new_pool = create_pool(
            get_pool_key_xstrk_strk_1(),
            get_bounds_xstrk_strk_3()
        );
        clVault.add_pool(new_pool);
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        
        // Use very small liquidity amounts
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(3 * pow::ten_pow(18));
        liq_array.append(2 * pow::ten_pow(18));
        liq_array.append(1 * pow::ten_pow(18));
        
        let rebal_params = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params);
        
        let pools = clVault.get_managed_pools();
        assert(pools.len() == 3, 'should have 3 pools');
        
        let liq2 = clVault.total_liquidity_per_pool(2);
        assert(liq2 > 0, 'pool 2 should have liquidity');
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('invalid token pair',))]
    fn test_add_pool_invalid_token_pair() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        
        // Try to add pool with wrong tokens (ETH/USDC instead of xSTRK/STRK)
        let invalid_pool = create_pool(
            get_pool_key_eth_usdc_1(),
            get_bounds_eth_usdc_1()
        );
        
        clVault.add_pool(invalid_pool);
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('pool already exists',))]
    fn test_add_pool_duplicate() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        
        // Try to add duplicate pool
        let duplicate_pool = create_pool(
            get_pool_key_xstrk_strk_1(),
            get_bounds_xstrk_strk_1()
        );
        
        clVault.add_pool(duplicate_pool);
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_remove_pool_after_draining() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        // Add third pool
        let new_pool = create_pool(
            get_pool_key_xstrk_strk_1(),
            get_bounds_xstrk_strk_3()
        );
        clVault.add_pool(new_pool);
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        
        // First rebalance to add liquidity to all pools - use very small amounts
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(3 * pow::ten_pow(18));
        liq_array.append(2 * pow::ten_pow(18));
        liq_array.append(1 * pow::ten_pow(18));
        let rebal_params1 = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params1);
        
        // Rebalance to drain pool 2
        let pools = clVault.get_managed_pools();
        let mut range_ins = ArrayTrait::<RangeInstruction>::new();
        let mut i = 0;
        while i != pools.len() {
            let pool = *pools.at(i);
            let current_liq = clVault.total_liquidity_per_pool(i.into());
            let ins = RangeInstruction {
                liquidity_mint: if i == 2 { 0 } else { current_liq.try_into().unwrap() },
                liquidity_burn: if i == 2 { current_liq.try_into().unwrap() } else { 0 },
                pool_key: pool.pool_key,
                new_bounds: pool.bounds
            };
            range_ins.append(ins);
            i += 1;
        }
        
        let rebal_params = RebalanceParams {
            rebal: range_ins,
            swap_params: create_empty_swap_params(clVault)
        };
        clVault.rebalance_pool(rebal_params);
        
        // Verify pool 2 is drained
        let liq2 = clVault.total_liquidity_per_pool(2);
        assert(liq2 / 10000 == 0, 'pool 2 should be drained');
        
        // Remove pool
        clVault.remove_pool(2);
        
        let pools_after = clVault.get_managed_pools();
        assert(pools_after.len() == 2, 'should have 2 pools');
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('liquidity must be zero',))]
    fn test_remove_pool_with_liquidity() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        
        // Rebalance to add liquidity - use very small amounts
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(5 * pow::ten_pow(18));
        liq_array.append(2 * pow::ten_pow(18));
        let rebal_params = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params);
        
        // Try to remove pool with liquidity (should fail)
        clVault.remove_pool(0);
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_three_pools_operations() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        // Add third pool
        let new_pool = create_pool(
            get_pool_key_xstrk_strk_1(),
            get_bounds_xstrk_strk_3()
        );
        clVault.add_pool(new_pool);
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares1 = clVault.deposit(amount, amount, this);
        assert(_shares1 > 0, 'first deposit succeeds');

        // must rebalance after first deposit
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(3 * pow::ten_pow(18));
        liq_array.append(2 * pow::ten_pow(18));
        liq_array.append(1 * pow::ten_pow(18));
        let rebal_params1 = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params1);

        // Second deposit
        init_tokens_xstrk_strk(amount * 2);
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let shares2 = clVault.deposit(amount, amount, this);
        assert(shares2 > 0, 'second deposit should succeed');

        // Rebalance across all 3 pools with very small amounts
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(3 * pow::ten_pow(18));
        liq_array.append(2 * pow::ten_pow(18));
        liq_array.append(1 * pow::ten_pow(18));
        
        let rebal_params = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params);

        // Verify all pools have liquidity
        let mut i: u32 = 0;
        while i != 3 {
            let liq = clVault.total_liquidity_per_pool(i.into());
            assert(liq > 0, 'pool should have liquidity');
            i += 1;
        }
        
        // Withdraw
        let total_shares = ERC20Helper::balanceOf(clVault.contract_address, this);
        let withdraw_shares = total_shares / 2;
        clVault.withdraw(withdraw_shares, this);
        
        let shares_after = ERC20Helper::balanceOf(clVault.contract_address, this);
        assert(shares_after == (total_shares - withdraw_shares), 'shares should be burned');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_add_remove_add_cycle() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        // Add pool
        let pool1 = create_pool(
            get_pool_key_xstrk_strk_1(),
            get_bounds_xstrk_strk_3()
        );
        clVault.add_pool(pool1);
        assert(clVault.get_managed_pools().len() == 3, 'should have 3 pools');
        
        // Deposit and drain pool 2
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);

        // First rebalance to add liquidity - use very small amounts
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(3 * pow::ten_pow(18));
        liq_array.append(2 * pow::ten_pow(18));
        liq_array.append(1 * pow::ten_pow(18));
        let rebal_params1 = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params1);

        // Drain pool 2
        let pools = clVault.get_managed_pools();
        let mut range_ins = ArrayTrait::<RangeInstruction>::new();
        let mut i = 0;
        while i != pools.len() {
            let pool = *pools.at(i);
            let current_liq = clVault.total_liquidity_per_pool(i.into());
            let ins = RangeInstruction {
                liquidity_mint: if i == 2 { 0 } else { current_liq.try_into().unwrap() },
                liquidity_burn: if i == 2 { current_liq.try_into().unwrap() } else { 0 },
                pool_key: pool.pool_key,
                new_bounds: pool.bounds
            };
            range_ins.append(ins);
            i += 1;
        }
        
        let rebal_params = RebalanceParams {
            rebal: range_ins,
            swap_params: create_empty_swap_params(clVault)
        };
        clVault.rebalance_pool(rebal_params);

        // Remove pool
        clVault.remove_pool(2);
        assert(clVault.get_managed_pools().len() == 2, 'should have 2 pools');

        clVault.add_pool(pool1);
        assert(clVault.get_managed_pools().len() == 3, 'should have 3 pools');
    }

    // ============================================================================
    // CATEGORY 3: PERMISSION TESTS
    // ============================================================================

    #[test]
    #[fork("mainnet_4707139")]
    fn test_set_settings_governor_only() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        
        // Should succeed (caller is governor by default in test setup)
        let fee_collector: ContractAddress = 0x123.try_into().unwrap();
        let fee_settings = FeeSettings {
            fee_bps: 1500,
            fee_collector: fee_collector
        };
        clVault.set_settings(fee_settings);
        
        let settings = clVault.get_fee_settings();
        assert(settings.fee_bps == 1500, 'fee_bps updated');
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('Access: Missing governor role',))]
    fn test_set_settings_unauthorized() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        
        start_cheat_caller_address(clVault.contract_address, constants::EKUBO_USER_ADDRESS());
        let fee_collector: ContractAddress = 0x123.try_into().unwrap();
        let fee_settings = FeeSettings {
            fee_bps: 1500,
            fee_collector: fee_collector
        };
        clVault.set_settings(fee_settings);
        stop_cheat_caller_address(clVault.contract_address);
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_add_pool_governor_only() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        
        // Should succeed (caller is governor)
        let new_pool = create_pool(
            get_pool_key_xstrk_strk_1(),
            get_bounds_xstrk_strk_3()
        );
        clVault.add_pool(new_pool);
        
        let pools = clVault.get_managed_pools();
        assert(pools.len() == 3, 'pool should be added');
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('Access: Missing governor role',))]
    fn test_add_pool_unauthorized() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        
        start_cheat_caller_address(clVault.contract_address, constants::EKUBO_USER_ADDRESS());
        let new_pool = create_pool(
            get_pool_key_xstrk_strk_1(),
            get_bounds_xstrk_strk_3()
        );
        clVault.add_pool(new_pool);
        stop_cheat_caller_address(clVault.contract_address);
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_remove_pool_governor_only() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        // Add third pool
        let new_pool = create_pool(
            get_pool_key_xstrk_strk_1(),
            get_bounds_xstrk_strk_3()
        );
        clVault.add_pool(new_pool);
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        
        // First rebalance to add liquidity - use very small amounts
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(3 * pow::ten_pow(18));
        liq_array.append(2 * pow::ten_pow(18));
        liq_array.append(1 * pow::ten_pow(18));
        let rebal_params1 = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params1);
        
        // Drain pool 2
        let pools = clVault.get_managed_pools();
        let mut range_ins = ArrayTrait::<RangeInstruction>::new();
        let mut i = 0;
        while i != pools.len() {
            let pool = *pools.at(i);
            let current_liq = clVault.total_liquidity_per_pool(i.into());
            let ins = RangeInstruction {
                liquidity_mint: if i == 2 { 0 } else { current_liq.try_into().unwrap() },
                liquidity_burn: if i == 2 { current_liq.try_into().unwrap() } else { 0 },
                pool_key: pool.pool_key,
                new_bounds: pool.bounds
            };
            range_ins.append(ins);
            i += 1;
        }
        
        let rebal_params = RebalanceParams {
            rebal: range_ins,
            swap_params: create_empty_swap_params(clVault)
        };
        clVault.rebalance_pool(rebal_params);
        
        // Governor can remove pool
        clVault.remove_pool(2);
        
        let pools_after = clVault.get_managed_pools();
        assert(pools_after.len() == 2, 'pool should be removed');
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('Access: Missing governor role',))]
    fn test_remove_pool_unauthorized() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        
        start_cheat_caller_address(clVault.contract_address, constants::EKUBO_USER_ADDRESS());
        clVault.remove_pool(0);
        stop_cheat_caller_address(clVault.contract_address);
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('Access: Missing relayer role',))]
    fn test_rebalance_unauthorized() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        
        let mut range_ins = ArrayTrait::<RangeInstruction>::new();
        let rebal_params = RebalanceParams {
            rebal: range_ins,
            swap_params: create_empty_swap_params(clVault)
        };
        
        start_cheat_caller_address(clVault.contract_address, constants::EKUBO_USER_ADDRESS());
        clVault.rebalance_pool(rebal_params);
        stop_cheat_caller_address(clVault.contract_address);
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_deposit_anyone() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        // Anyone can deposit (no role check)
        let shares = clVault.deposit(amount, amount, this);
        assert(shares > 0, 'deposit should succeed');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_withdraw_anyone() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        let total_shares = ERC20Helper::balanceOf(clVault.contract_address, this);
        
        // Anyone can withdraw their shares
        clVault.withdraw(total_shares / 2, this);
        
        let shares_after = ERC20Helper::balanceOf(clVault.contract_address, this);
        assert(shares_after > 0, 'should have remaining shares');
    }

    // ============================================================================
    // CATEGORY 4: PAUSABILITY TESTS
    // ============================================================================

    #[test]
    #[fork("mainnet_4707139")]
    fn test_pause_emergency_actor() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let common = get_common_dispatcher(clVault);
        
        // Emergency actor can pause (caller is emergency actor in test setup)
        common.pause();
        
        // Verify paused
        let is_paused = common.is_paused();
        assert(is_paused == true, 'should be paused');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_unpause_emergency_actor() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let common = get_common_dispatcher(clVault);
        
        common.pause();
        common.unpause();
        
        let is_paused = common.is_paused();
        assert(is_paused == false, 'should be unpaused');
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('Access: Missing EA role',))]
    fn test_pause_unauthorized() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let common = get_common_dispatcher(clVault);
        
        start_cheat_caller_address(clVault.contract_address, constants::EKUBO_USER_ADDRESS());
        common.pause();
        stop_cheat_caller_address(clVault.contract_address);
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('Pausable: paused',))]
    fn test_deposit_when_paused() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let common = get_common_dispatcher(clVault);
        let this = get_contract_address();
        
        common.pause();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount);
        
        clVault.deposit(amount, amount, this);
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('Pausable: paused',))]
    fn test_withdraw_when_paused() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let common = get_common_dispatcher(clVault);
        let this = get_contract_address();
        
        // Deposit first
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        let total_shares = ERC20Helper::balanceOf(clVault.contract_address, this);
        
        // Pause and try to withdraw
        common.pause();
        clVault.withdraw(total_shares / 2, this);
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('Pausable: paused',))]
    fn test_handle_fees_when_paused() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let common = get_common_dispatcher(clVault);
        
        common.pause();
        clVault.handle_fees(0);
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_rebalance_when_paused() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let common = get_common_dispatcher(clVault);
        let this = get_contract_address();
        
        // Deposit first
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        
        // Pause
        common.pause();
        
        // Rebalance should still work (non-pausable) - use very small amounts
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(5 * pow::ten_pow(18));
        liq_array.append(2 * pow::ten_pow(18));
        
        let rebal_params = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params);
        
        let liq0 = clVault.total_liquidity_per_pool(0);
        assert(liq0 > 0, 'rebalance works when paused');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_set_settings_when_paused() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let common = get_common_dispatcher(clVault);
        
        common.pause();
        
        // Set settings should still work (non-pausable)
        let fee_collector: ContractAddress = 0x456.try_into().unwrap();
        let fee_settings = FeeSettings {
            fee_bps: 2000,
            fee_collector: fee_collector
        };
        clVault.set_settings(fee_settings);
        
        let settings = clVault.get_fee_settings();
        assert(settings.fee_bps == 2000, 'settings updated when paused');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_add_pool_when_paused() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let common = get_common_dispatcher(clVault);
        
        common.pause();
        
        // Add pool should still work (non-pausable)
        let new_pool = create_pool(
            get_pool_key_xstrk_strk_1(),
            get_bounds_xstrk_strk_3()
        );
        clVault.add_pool(new_pool);
        
        let pools = clVault.get_managed_pools();
        assert(pools.len() == 3, 'pool added when paused');
    }

    // ============================================================================
    // CATEGORY 5: EDGE CASES & ERROR HANDLING
    // ============================================================================

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('amounts cannot be zero',))]
    fn test_deposit_zero_amounts() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        clVault.deposit(0, 0, this);
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('insufficient shares',))]
    fn test_withdraw_insufficient_shares() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        
        // Try to withdraw more than owned
        clVault.withdraw(1000000 * pow::ten_pow(18), this);
    }

    #[test]
    #[fork("mainnet_4707139")]
    #[should_panic(expected: ('pool_key mismatch',))]
    fn test_rebalance_invalid_pool_key() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        
        // Create rebalance params with wrong pool key
        let pools = clVault.get_managed_pools();
        let mut range_ins = ArrayTrait::<RangeInstruction>::new();
        let mut i = 0;
        while i != pools.len() {
            let pool = *pools.at(i);
            // Use wrong pool key for first pool
            let wrong_key = if i == 0 {
                get_pool_key_eth_usdc_1() // Wrong token pair
            } else {
                pool.pool_key
            };
            let ins = RangeInstruction {
                liquidity_mint: 1000,
                liquidity_burn: 0,
                pool_key: wrong_key,
                new_bounds: pool.bounds
            };
            range_ins.append(ins);
            i += 1;
        }
        
        let rebal_params = RebalanceParams {
            rebal: range_ins,
            swap_params: create_empty_swap_params(clVault)
        };
        
        clVault.rebalance_pool(rebal_params);
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_convert_to_shares_zero_supply() {
        let (clVault, erc20Disp) = deploy_vault_xstrk_strk();
        
        assert(erc20Disp.total_supply() == 0, 'total supply should be 0');
        
        let amount0 = 10 * pow::ten_pow(18);
        let amount1 = 10 * pow::ten_pow(18);
        
        let shares_info = clVault.convert_to_shares(amount0, amount1);
        
        let SCALE_18 = 1_000_000_000_000_000_000_u256;
        let init1 = 2 * SCALE_18;
        let expected_shares = (SCALE_18 * amount0 / SCALE_18 + SCALE_18 * amount1 / init1) / 2;
        assert(shares_info.shares > 0, 'shares should be calculated');
        assert(shares_info.shares == expected_shares, 'shares should be calculated');
        assert(shares_info.vault_level_positions.positions.len() == 0, 'vault positions should be empty');
        assert(shares_info.vault_level_positions.total_amount0 == 0, 'vault amount0 should be 0');
        assert(shares_info.vault_level_positions.total_amount1 == 0, 'vault amount1 should be 0');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_convert_to_shares_after_deposit() {
        let (clVault, erc20Disp) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares1 = clVault.deposit(amount, amount, this);
        
        // Rebalance to add liquidity first - use very small amounts
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(5 * pow::ten_pow(18));
        liq_array.append(2 * pow::ten_pow(18));
        let rebal_params = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params);
        
        // Convert to shares after deposit and rebalance
        let shares_info = clVault.convert_to_shares(amount, amount);
        assert(shares_info.shares > 0, 'shares error');
        assert(shares_info.shares == 1152034540170218661139, 'shares error2');
        assert(shares_info.vault_level_positions.positions.len() == 2, 'should have 2 vault positions');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_convert_to_assets() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let shares = clVault.deposit(amount, amount, this);
        
        // Rebalance to add liquidity - use very small amounts
        let mut liq_array = ArrayTrait::<u256>::new();
        liq_array.append(5 * pow::ten_pow(18));
        liq_array.append(2 * pow::ten_pow(18));
        let rebal_params = create_rebalance_params(clVault, liq_array);
        clVault.rebalance_pool(rebal_params);
        
        let assets = clVault.convert_to_assets(shares);
        assert(assets.positions.len() == 2, 'should have 2 positions');
        assert(assets.total_amount0 > 0 || assets.total_amount1 > 0, 'should have assets');
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_handle_fees_no_fees() {
        let (clVault, _) = deploy_vault_xstrk_strk();
        let this = get_contract_address();
        
        let amount = 10 * pow::ten_pow(18);
        init_tokens_xstrk_strk(amount * 2);
        
        ERC20Helper::approve(constants::XSTRK_ADDRESS(), clVault.contract_address, amount * 2);
        ERC20Helper::approve(constants::STRK_ADDRESS(), clVault.contract_address, amount * 2);
        
        let _shares = clVault.deposit(amount, amount, this);
        
        // Handle fees when no fees accrued (should not fail)
        clVault.handle_fees(0);
        
        let position = clVault.get_position(0);
        assert(position.liquidity >= 0, 'liquidity non-negative');
    }
}
