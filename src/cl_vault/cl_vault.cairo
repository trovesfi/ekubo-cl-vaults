#[starknet::contract]
mod ConcLiquidityVault {
    use starknet::{
        storage::{
            StoragePointerReadAccess, StoragePointerWriteAccess, Vec, VecTrait, MutableVecTrait, Map,
            StorageMapReadAccess, StorageMapWriteAccess,
        },
        ClassHash, SyscallResultTrait,
        ContractAddress, get_contract_address, get_caller_address, get_block_timestamp,
    };
    use core::num::traits::Sqrt;
    use openzeppelin::interfaces::accesscontrol::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use openzeppelin::security::reentrancyguard::ReentrancyGuardComponent;
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::token::erc20::{ERC20Component, ERC20HooksEmptyImpl, DefaultConfig};
    use openzeppelin::interfaces::erc20::IERC20Mixin;
    use starkware_utils::components::roles::RolesComponent;
    use starkware_utils::components::roles::RolesComponent::InternalTrait as RolesInternalTrait;
    use starkware_utils::components::common_roles::CommonRolesComponent;
    use starkware_utils::components::pausable::PausableComponent;
    use starkware_utils::components::pausable::PausableComponent::InternalTrait as PausableInternalTrait;
    use starkware_utils::components::replaceability::ReplaceabilityComponent;
    use starkware_utils::components::replaceability::ReplaceabilityComponent::InternalReplaceabilityTrait;
    use troves_clvaults::ekubo::{
        types::{
            pool_price::PoolPrice,
            position::Position,
            i129::i129
        },
        interfaces::mathlib::{IMathLibDispatcherTrait, dispatcher as ekuboLibDispatcher}
    };
    use troves_clvaults::helpers::{pow, ERC20Helper};
    use troves_clvaults::components::swap::{AvnuMultiRouteSwap, AvnuMultiRouteSwapImpl};
    use troves_clvaults::{
        cl_vault::{
            interface::{
                *,
                Events::*
            },
            errors::Errors
        },
        interfaces::{
            IEkuboPosition::{IEkuboDispatcher, IEkuboDispatcherTrait},
            IEkuboPositionsNFT::{IEkuboNFTDispatcher, IEkuboNFTDispatcherTrait},
            IEkuboCore::{
                IEkuboCoreDispatcher,
                IEkuboCoreDispatcherTrait,
                Bounds,
                PositionKey,
                PoolKey
            },
            IEkuboDistributor::{
                IEkuboDistributorDispatcherTrait, Claim, IEkuboDistributorDispatcher,
            },
            IVesuOracle::{IVesuOracleDispatcher, IVesuOracleDispatcherTrait}
        }
    };

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: ReentrancyGuardComponent, storage: reng, event: ReentrancyGuardEvent);
    // StarkWare roles (as in starknet-staking): GOVERNANCE_ADMIN, APP_GOVERNOR, OPERATOR,
    // SECURITY_AGENT (pause) / SECURITY_GOVERNOR (unpause), UPGRADE_GOVERNOR (+ delayed upgrades)
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: CommonRolesComponent, storage: common_roles, event: CommonRolesEvent);
    component!(path: RolesComponent, storage: roles, event: RolesEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(path: ReplaceabilityComponent, storage: replaceability, event: ReplaceabilityEvent);

    #[abi(embed_v0)]
    impl ERC20MixinImpl = ERC20Component::ERC20MixinImpl<ContractState>;
    #[abi(embed_v0)]
    impl RolesImpl = RolesComponent::RolesImpl<ContractState>;
    #[abi(embed_v0)]
    impl CommonRolesImpl = CommonRolesComponent::CommonRolesImpl<ContractState>;
    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;
    #[abi(embed_v0)]
    impl ReplaceabilityImpl = ReplaceabilityComponent::ReplaceabilityImpl<ContractState>;

    // Internal impls
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;

    pub const SCALE_18: u256 = 1_000_000_000_000_000_000;
    // hard caps (cannot be exceeded by governor settings)
    pub const MAX_FEE_BPS: u256 = 10000; // 100%: governor decides; only sanity-bounded
    pub const MAX_REBALANCE_SLIPPAGE_BPS: u32 = 10000; // sanity bound only; governor decides
    pub const MAX_TICK_MAGNITUDE: u128 = 88722883; // Ekubo
    pub const TWO_POW_128: u256 = 0x100000000000000000000000000000000;
    pub const TWO_POW_64: u256 = 0x10000000000000000;
    // shares minted to the vault itself on the first deposit and never redeemable
    // (prevents first-depositor share-price inflation / donation attacks)
    pub const DEAD_SHARES: u256 = 1000;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        reng: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        accesscontrol: AccessControlComponent::Storage,
        #[substorage(v0)]
        common_roles: CommonRolesComponent::Storage,
        #[substorage(v0)]
        roles: RolesComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        replaceability: ReplaceabilityComponent::Storage,
        // v1 only: the external troves AccessControl (same slot as troves CommonComp's
        // `access_control`). Read once by initialize_roles_from_v1, never written.
        access_control: ContractAddress,
        // constants
        ekubo_positions_contract: IEkuboDispatcher,
        ekubo_positions_nft: ContractAddress,
        ekubo_core: ContractAddress,
        oracle: ContractAddress,
        // Changeable settings
        fee_settings: FeeSettings,
        max_unused_balances_on_rebalance: MaxUnusedBalances, // allows governor to set max unused balances on rebalance
        managed_pools: Vec<ManagedPool>,
        // contract managed state
        sqrt_values: Vec<SqrtValues>, // sqrt values for each pool (same order as managed_pools)
        init_values: InitValues, // initial ratios for token distribution, responsible for setting the mathematical order of shares for new vaults
        // relayer guard-rails (appended in hardening upgrade)
        rebalance_settings: RebalanceSettings,
        last_rebalance_ts: u64,
        // governor/admin callers must be timelocks with get_min_delay() >= this (0 = not enforced,
        // only possible on vaults upgraded from v1 until the migration sets it)
        min_timelock_delay: u64,
        // allowlisted timelock classes -> selector of their delay getter (0 = not allowed), e.g.
        // OZ TimelockController: get_min_delay, StarkWare MultiExecutor: get_execution_delay
        allowed_timelock_classes: Map<ClassHash, felt252>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        ERC20Event: ERC20Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        CommonRolesEvent: CommonRolesComponent::Event,
        #[flat]
        RolesEvent: RolesComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        ReplaceabilityEvent: ReplaceabilityComponent::Event,
        Deposit: Deposit,
        Withdraw: Withdraw,
        Rebalance: Rebalance,
        HandleFees: HandleFees,
        FeeSettings: FeeSettings,
        MaxUnusedBalances: MaxUnusedBalances,
        RebalanceSettings: RebalanceSettings,
        OracleUpdated: OracleUpdated,
        MinTimelockDelayUpdated: MinTimelockDelayUpdated,
        TimelockClassUpdated: TimelockClassUpdated,
        Harvest: HarvestEvent,
        PoolUpdated: PoolUpdated,
        EkuboPositionUpdated: EkuboPositionUpdated,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: ByteArray,
        symbol: ByteArray,
        governance_admin: ContractAddress,
        ekubo_positions_contract: ContractAddress,
        ekubo_positions_nft: ContractAddress,
        ekubo_core: ContractAddress,
        oracle: ContractAddress,
        fee_settings: FeeSettings,
        init_values: InitValues,
        managed_pools: Array<ManagedPool>,
        min_timelock_delay: u64,
        allowed_timelocks: Array<TimelockClass>,
    ) {
        assert(allowed_timelocks.len() > 0, 'no timelock class');
        for t in allowed_timelocks.span() {
            self._set_timelock_class(*t.class_hash, *t.delay_selector);
        };
        assert(min_timelock_delay > 0, 'invalid min timelock delay');
        self.min_timelock_delay.write(min_timelock_delay);
        self.erc20.initializer(name, symbol);
        self.roles.initialize(:governance_admin);
        // upgrades: add_new_implementation -> wait upgrade_delay -> replace_to (UPGRADE_GOVERNOR)
        self.replaceability.initialize(upgrade_delay: min_timelock_delay);
        self
            .ekubo_positions_contract
            .write(IEkuboDispatcher { contract_address: ekubo_positions_contract });
        self.ekubo_positions_nft.write(ekubo_positions_nft);
        self.ekubo_core.write(ekubo_core);

        // add all pools
        assert(managed_pools.len() != 0, 'empty pool list');
        let mut i = 0;
        while i != managed_pools.len() {
            let pool_ref = managed_pools.at(i);
            self._modify_pool(*pool_ref, true);
            i += 1;
        }

        self.oracle.write(oracle);
        self._assert_valid_fee_settings(fee_settings);
        self.fee_settings.write(fee_settings);
        assert(init_values.init0 != 0, 'invalid init0');
        assert(init_values.init1 != 0, 'invalid init1');
        self.init_values.write(init_values);
        // Initialize max unused balances to 0 (disabled by default)
        self.max_unused_balances_on_rebalance.write(MaxUnusedBalances { token0: 0, token1: 0 });
        // conservative defaults; governor is expected to tune per vault
        self.rebalance_settings.write(default_rebalance_settings());
    }

    #[derive(Drop, starknet::Event)]
    struct TimelockClassUpdated {
        #[key]
        class_hash: ClassHash,
        delay_selector: felt252, // 0 = removed
    }

    #[derive(Drop, starknet::Event)]
    struct MinTimelockDelayUpdated {
        min_delay: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct OracleUpdated {
        oracle: ContractAddress,
    }

    fn default_rebalance_settings() -> RebalanceSettings {
        RebalanceSettings {
            max_slippage_bps: 100, // 1%
            max_pool_tick_deviation: 10000, // ~1% (1 tick ~= 1e-6 relative price)
            max_bounds_distance: 300000, // ~35%
            min_rebalance_interval: 0,
            max_swap_amount0: core::num::traits::Bounded::<u256>::MAX,
            max_swap_amount1: core::num::traits::Bounded::<u256>::MAX,
        }
    }

    /// floor(a * b / c) with a 512-bit intermediate; reverts if the result exceeds u256.
    fn mul_div(a: u256, b: u256, c: u256) -> u256 {
        let prod: core::integer::u512 = core::num::traits::WideMul::wide_mul(a, b);
        let (q, _) = core::integer::u512_safe_div_rem_by_u256(prod, c.try_into().expect('mul_div by zero'));
        assert(q.limb2 == 0 && q.limb3 == 0, 'mul_div overflow');
        u256 { low: q.limb0, high: q.limb1 }
    }

    fn ceil_div(a: u256, b: u256) -> u256 {
        if a == 0 { 0 } else { (a - 1) / b + 1 }
    }

    /// |a - b| for i129 ticks
    fn tick_distance(a: i129, b: i129) -> u128 {
        if a.sign == b.sign || a.mag == 0 || b.mag == 0 {
            if a.mag >= b.mag { a.mag - b.mag } else { b.mag - a.mag }
        } else {
            a.mag + b.mag
        }
    }

    fn assert_valid_bounds(pool_key: PoolKey, bounds: Bounds) {
        assert(bounds.lower < bounds.upper, 'invalid bounds order');
        assert(
            bounds.lower.mag <= MAX_TICK_MAGNITUDE && bounds.upper.mag <= MAX_TICK_MAGNITUDE,
            'bounds out of range'
        );
        assert(
            bounds.lower.mag % pool_key.tick_spacing == 0
                && bounds.upper.mag % pool_key.tick_spacing == 0,
            'bounds not aligned'
        );
    }


    #[abi(embed_v0)]
    impl ExternalImpl of IClVault<ContractState> {
        /// @notice Deposits assets into the contract and mints corresponding shares.
        /// @dev Uses at most amount0/amount1; the vault's token ratio (positions + idle) decides
        ///      how much of each is actually pulled. No minimum shares (see deposit_with_min).
        fn deposit(
            ref self: ContractState, amount0: u256, amount1: u256, receiver: ContractAddress
        ) -> u256 {
            self._deposit(amount0, amount1, receiver, 0)
        }

        /// @notice Same as deposit, reverts if fewer than min_shares would be minted.
        fn deposit_with_min(
            ref self: ContractState,
            amount0: u256,
            amount1: u256,
            receiver: ContractAddress,
            min_shares: u256
        ) -> u256 {
            self._deposit(amount0, amount1, receiver, min_shares)
        }

        /// @notice Withdraws assets by redeeming shares from the contract.
        /// @dev Not pausable: users can always exit. No minimum-out (see withdraw_with_min).
        fn withdraw(
            ref self: ContractState, shares: u256, receiver: ContractAddress
        ) -> MyPositions {
            self._withdraw(shares, receiver, 0, 0)
        }

        /// @notice Withdraw with user-specified minimum amounts received.
        fn withdraw_with_min(
            ref self: ContractState,
            shares: u256,
            receiver: ContractAddress,
            min_amount0: u256,
            min_amount1: u256
        ) -> MyPositions {
            self._withdraw(shares, receiver, min_amount0, min_amount1)
        }

        /// @notice Converts given asset amounts into the corresponding number of shares.
        /// @dev no compulsion to use entire amount0 and amount1, can use partial amounts
        fn convert_to_shares(self: @ContractState, amount0: u256, amount1: u256) -> SharesInfo {
            self._convert_to_shares(amount0, amount1)
        }

        /// @notice Converts shares into the corresponding asset amounts.
        /// @dev Proportionally convert shares to assets across all pools
        fn convert_to_assets(self: @ContractState, shares: u256) -> MyPositions {
            let mut i = 0;
            let mut total_amount0 = 0;
            let mut total_amount1 = 0;
            let mut positions = ArrayTrait::<MyPosition>::new();
            let supply = self.total_supply();
            while i != self.managed_pools.len() {
                let liquidity = self._convert_to_liquidity(shares, i, supply);
                // withdrawal direction: round amounts down
                let (amt0, amt1) = self._liquidity_to_amounts_down(i, liquidity);
                positions.append(MyPosition { liquidity, amount0: amt0, amount1: amt1 });
                total_amount0 += amt0;
                total_amount1 += amt1;
                i += 1;
            }
            // pro-rata share of idle balances
            if supply > 0 {
                let (idle0, idle1) = self._idle_balances();
                total_amount0 += idle0 * shares / supply;
                total_amount1 += idle1 * shares / supply;
            }
            return MyPositions {
                positions: positions,
                total_amount0: total_amount0,
                total_amount1: total_amount1
            };
        }

        /// @notice Returns the total ekubo liquidity of the pool.
        fn total_liquidity_per_pool(self: @ContractState, pool_index: u64) -> u256 {
            let pool = self.managed_pools[pool_index].read();
            let position_key = PositionKey {
                salt: pool.nft_id,
                owner: self.ekubo_positions_contract.read().contract_address,
                bounds: pool.bounds
            };
            let curr_position: Position = IEkuboCoreDispatcher {
                contract_address: self.ekubo_core.read()
            }
                .get_position(pool.pool_key, position_key);

            curr_position.liquidity.into()
        }

                /// @notice Retrieves the current position details from the Ekubo core contract.
        /// @dev This function fetches the position data using the contract's position key
        /// and pool key from the Ekubo core contract.
        /// @return curr_position The current position details.
        fn get_position(self: @ContractState, pool_index: u64) -> MyPosition {
            let pool = self.managed_pools[pool_index].read();
            let (range_amount0, range_amount1, range_liq) = self._get_range_amounts(pool);
            MyPosition {
                liquidity: range_liq.into(),
                amount0: range_amount0.into(),
                amount1: range_amount1.into(),
            }
        }

        fn get_positions(self: @ContractState) -> MyPositions {
            let mut positions = ArrayTrait::<MyPosition>::new();
            let mut i = 0;
            let mut total_amount0 = 0;
            let mut total_amount1 = 0;
            while i != self.managed_pools.len() {
                let position = self.get_position(i);
                positions.append(position);
                total_amount0 += position.amount0;
                total_amount1 += position.amount1;
                i += 1;
            }
            MyPositions { 
                positions: positions,
                total_amount0: total_amount0,
                total_amount1: total_amount1
            }
        }

        /// @notice Collects and handles fees generated by the contract.
        /// @dev Collects LP fees, takes the strategy fee, re-deposits the rest into the range.
        fn handle_fees(ref self: ContractState, pool_index: u64) {
            self.reng.start();
            self.pausable.assert_not_paused();
            self._handle_fees(pool_index);
            self.reng.end();
        }

        /// @notice Harvests rewards from the specified rewards contract.
        /// reward token (e.g. STRK) -> token0 and token1 
        fn harvest(
            ref self: ContractState,
            rewardsContract: ContractAddress,
            claim: Claim,
            proof: Span<felt252>,
            swapInfo1: AvnuMultiRouteSwap,
            swapInfo2: AvnuMultiRouteSwap
        ) {
            self.reng.start();
            self.pausable.assert_not_paused();
            self.roles.only_operator();
            let max_slippage_bps = self.rebalance_settings.read().max_slippage_bps;

            // claim rewards
            let (rewardToken, mut reward_amt) = self._ekubo_harvest(rewardsContract, claim, proof);

            // collect fees
            let fee_settings = self.fee_settings.read();
            let fee_amount = reward_amt * fee_settings.fee_bps / 10000;
            if (fee_amount > 0) {
                ERC20Helper::transfer(rewardToken, fee_settings.fee_collector, fee_amount);
                reward_amt -= fee_amount;
            }

            // validate swap info
            // aim to swap 100% of STRK into token0 and token1
            let pool = self.managed_pools[0].read();
            let token0 = pool.pool_key.token0;
            let token1 = pool.pool_key.token1;
            assert(
                swapInfo1.token_from_address == rewardToken,
                'invalid token from address [1]'
            );
            assert(swapInfo1.token_to_address == token0, 'invalid token to address [1]');
            assert(
                swapInfo2.token_from_address == rewardToken,
                'invalid token from address [2]'
            );
            assert(swapInfo2.token_to_address == token1, 'invalid token to address [2]');
            assert(reward_amt > 0, 'No harvest amt');
            assert(
                swapInfo1.token_from_amount + swapInfo2.token_from_amount == reward_amt,
                'invalid reward token balance'
            );

            let mut token0_amt: u256 = swapInfo1.token_from_amount;
            if (swapInfo1.token_from_amount > 0
                && swapInfo1.token_from_address != swapInfo1.token_to_address) {
                token0_amt = self._oracle_checked_swap(swapInfo1, max_slippage_bps);
            }
            let mut token1_amt: u256 = swapInfo2.token_from_amount;
            if (swapInfo2.token_from_amount > 0
                && swapInfo2.token_from_address != swapInfo2.token_to_address) {
                token1_amt = self._oracle_checked_swap(swapInfo2, max_slippage_bps);
            }

            self
                .emit(
                    HarvestEvent {
                        rewardToken: rewardToken,
                        rewardAmount: reward_amt,
                        token0: token0,
                        token0Amount: token0_amt,
                        token1: token1,
                        token1Amount: token1_amt
                    }
                );
            self.reng.end();
        }

        /// @notice Retrieves the current settings of the contract + pool info
        fn get_pool_settings(self: @ContractState, pool_index: u64) -> ClSettings {
            let pool = self.managed_pools[pool_index].read();
            ClSettings {
                ekubo_positions_contract: self.ekubo_positions_contract.read().contract_address,
                bounds_settings: pool.bounds,
                pool_key: pool.pool_key,
                ekubo_positions_nft: self.ekubo_positions_nft.read(),
                contract_nft_id: pool.nft_id,
                ekubo_core: self.ekubo_core.read(),
                oracle: self.oracle.read(),
                fee_settings: self.fee_settings.read()
            }
        }

        fn get_managed_pools(self: @ContractState) -> Array<ManagedPool> {
            let mut pools = ArrayTrait::<ManagedPool>::new();
            let mut i = 0;
            while i != self.managed_pools.len() {
                pools.append(self.managed_pools[i].read());
                i += 1;
            }

            pools
        }

        /// @notice Updates the fee settings of the contract.
        fn set_settings(ref self: ContractState, fee_settings: FeeSettings) {
            self.roles.only_app_governor();
            self._assert_timelocked_caller();
            self._assert_valid_fee_settings(fee_settings);
            self.fee_settings.write(fee_settings);
            self.emit(fee_settings);
        }

        /// @notice Updates the maximum unused token balances allowed after rebalance.
        fn set_max_unused_balances_on_rebalance(
            ref self: ContractState, 
            max_unused_balances: MaxUnusedBalances
        ) {
            self.roles.only_app_governor();
            self._assert_timelocked_caller();
            self.max_unused_balances_on_rebalance.write(max_unused_balances);
            self.emit(max_unused_balances);
        }

        /// @notice Rebalances the liquidity position based on new bounds.
        /// @dev Withdraws liquidity (collecting fees first), swaps between token0/token1 with an
        ///      unconditional oracle check, optionally moves bounds (only for empty ranges, within
        ///      the oracle band) and redeposits liquidity at a pool price close to the oracle.
        fn rebalance_pool(
            ref self: ContractState, 
            rebalance_params: RebalanceParams
        ) {
            self.reng.start();
            self.pausable.assert_not_paused();
            self.roles.only_operator();
            let settings = self.rebalance_settings.read();

            // rate limit
            let now = get_block_timestamp();
            let last = self.last_rebalance_ts.read();
            if last != 0 {
                assert(now >= last + settings.min_rebalance_interval, 'rebalance too soon');
            }
            self.last_rebalance_ts.write(now);

            assert(rebalance_params.rebal.len().into() == self.managed_pools.len(), 'invalid rebal len');
            let mut i = 0;

            // assert same pool keys (intend to only rebalance between same pool keys)
            while i != self.managed_pools.len() {
                let stored_pool = self.managed_pools[i].read();
                let input_pool_key = *rebalance_params.rebal.at(i.try_into().unwrap()).pool_key;
        
                assert(
                    stored_pool.pool_key == input_pool_key,
                    'pool_key mismatch'
                );
                i += 1;
            }

            i = 0;
            while i != self.managed_pools.len() {
                let rebal_params = *rebalance_params.rebal.at(i.try_into().unwrap());

                if (rebal_params.liquidity_burn == 0) {
                    // no intent to withdraw liquidity
                    i += 1;
                    continue;
                }

                // assert liquidity to withdraw is valid
                let pool_liq = self.total_liquidity_per_pool(pool_index: i);
                if rebal_params.liquidity_burn.into() > pool_liq {
                    Errors::invalid_liquidity_burn_at_index(i);
                }

                // collect accrued fees (and strategy fee) before touching liquidity,
                // so nothing is left behind in the position
                let pool = self.managed_pools[i].read();
                self._collect_strat_fee(pool);

                let liq_to_withdraw = rebal_params.liquidity_burn.into();
                self._withdraw_position(liq_to_withdraw, i);
                i += 1;
            }
            
            // swap (token0 <-> token1 only, capped, always oracle-checked)
            if rebalance_params.swap_params.token_from_amount > 0 {
                self._checked_rebalance_swap(rebalance_params.swap_params, settings);
            }

            // mint liquidity
            i = 0;
            let this = get_contract_address();
            while i != self.managed_pools.len() {
                let pool = self.managed_pools[i].read();
                let rebal_params = *rebalance_params.rebal.at(i.try_into().unwrap());

                if rebal_params.liquidity_mint == 0 {
                    // no intent to mint liquidity
                    i += 1;
                    continue;
                }

                let oracle_tick = self._oracle_tick(pool.pool_key);
                // do not mint at a manipulated pool price
                let pool_tick = self._get_pool_price(i).tick;
                assert(
                    tick_distance(pool_tick, oracle_tick) <= settings.max_pool_tick_deviation,
                    'pool price off oracle'
                );

                // update pool bounds (further computations depend on the new bounds)
                let new_bounds = rebal_params.new_bounds;
                if new_bounds != pool.bounds {
                    // never orphan liquidity in the old range
                    assert(self.total_liquidity_per_pool(i) == 0, 'liquidity must be zero');
                    assert_valid_bounds(pool.pool_key, new_bounds);
                    assert(
                        tick_distance(new_bounds.lower, oracle_tick) <= settings.max_bounds_distance
                            && tick_distance(new_bounds.upper, oracle_tick) <= settings.max_bounds_distance,
                        'bounds too far from oracle'
                    );
                    assert(self._find_pool_index(pool.pool_key, new_bounds).is_none(), 'pool already exists');
                    self._set_pool_data(ManagedPoolField::Bounds(new_bounds), i);
                    self.sqrt_values[i].write(self._create_sqrt_values(new_bounds));
                }

                // assert sufficient token balances
                let token0_bal = ERC20Helper::balanceOf(pool.pool_key.token0, this);
                let token1_bal = ERC20Helper::balanceOf(pool.pool_key.token1, this);
                let liquidity = rebal_params.liquidity_mint;
                let (delta_amt0, delta_amt1) = self._calculate_liquidity_delta(i, (liquidity).into());
                
                if (token0_bal < delta_amt0.mag.into()) {
                    Errors::insufficient_amt0_at_index(i, delta_amt0.mag, token0_bal);
                }
                if (token1_bal < delta_amt1.mag.into()) {
                    Errors::insufficient_amt1_at_index(i, delta_amt1.mag, token1_bal);
                }

                self._ekubo_deposit(
                    this, 
                    delta_amt0.mag.into(), 
                    delta_amt1.mag.into(),  
                    this, 
                    i,
                    0
                );

                i += 1;
            }

            // Check unused token balances if thresholds are set in config
            let max_unused_balances = self.max_unused_balances_on_rebalance.read();
            if (max_unused_balances.token0 > 0 || max_unused_balances.token1 > 0) {
                let pool = self.managed_pools[0].read();
                let token0_bal = ERC20Helper::balanceOf(pool.pool_key.token0, this);
                let token1_bal = ERC20Helper::balanceOf(pool.pool_key.token1, this);
                
                if (max_unused_balances.token0 > 0 && token0_bal > max_unused_balances.token0) {
                    Errors::excessive_unused_token0(expected_max: max_unused_balances.token0, found: token0_bal);
                }
                if (max_unused_balances.token1 > 0 && token1_bal > max_unused_balances.token1) {
                    Errors::excessive_unused_token1(expected_max: max_unused_balances.token1, found: token1_bal);
                }
            }

            self
                .emit(
                    Rebalance {
                        actions: rebalance_params.rebal
                    }
                );
            self.reng.end();
        }

        /// @notice Updates relayer guard-rails (governor decision; only sanity-bounded).
        fn set_rebalance_settings(ref self: ContractState, settings: RebalanceSettings) {
            self.roles.only_app_governor();
            self._assert_timelocked_caller();
            assert(settings.max_slippage_bps <= MAX_REBALANCE_SLIPPAGE_BPS, 'slippage bps too high');
            assert(settings.max_pool_tick_deviation <= MAX_TICK_MAGNITUDE, 'tick deviation too high');
            assert(settings.max_bounds_distance <= MAX_TICK_MAGNITUDE, 'bounds distance too high');
            self.rebalance_settings.write(settings);
            self.emit(settings);
        }

        fn set_oracle(ref self: ContractState, oracle: ContractAddress) {
            self.roles.only_app_governor();
            self._assert_timelocked_caller();
            self.oracle.write(oracle);
            // sanity: must price both vault tokens validly right now
            let pool = self.managed_pools[0].read();
            self._price(pool.pool_key.token0);
            self._price(pool.pool_key.token1);
            self.emit(OracleUpdated { oracle });
        }

        fn add_pool(ref self: ContractState, pool: ManagedPool) {
            self.roles.only_app_governor();
            self._assert_timelocked_caller();
            self._modify_pool(pool, true);
        }

        fn remove_pool(ref self: ContractState, pool_index: u64) {
            self.roles.only_app_governor();
            self._assert_timelocked_caller();
            let pool = self.managed_pools[pool_index].read();
            self._modify_pool(pool, false);
        }

        fn get_amount_delta(self: @ContractState, pool_index: u64, liquidity: u256) -> (u256, u256) {
            let (delta_amt0, delta_amt1) = self._calculate_liquidity_delta(pool_index, liquidity);
            (delta_amt0.mag.into(), delta_amt1.mag.into())
        }

        fn get_liquidity_delta(self: @ContractState, pool_index: u64, amount0: u256, amount1: u256) -> u128 {
            let sqrt_values = self.sqrt_values[pool_index].read();
            let liquidity_delta = ekuboLibDispatcher().max_liquidity(
                self._get_pool_price(pool_index).sqrt_ratio,
                sqrt_values.sqrt_lower,
                sqrt_values.sqrt_upper,
                amount0.try_into().unwrap(),
                amount1.try_into().unwrap()
            );
            
            return liquidity_delta;
        }

        fn get_fee_settings(self: @ContractState) -> FeeSettings {
            self.fee_settings.read()
        }

        fn get_max_unused_balances_on_rebalance(self: @ContractState) -> MaxUnusedBalances {
            self.max_unused_balances_on_rebalance.read()
        }

        fn get_managed_pools_len(self: @ContractState) -> u64 {
            self.managed_pools.len()
        }

        fn get_managed_pool(self: @ContractState, index: u64) -> ManagedPool {
            self.managed_pools[index].read()
        }

        /// @notice One-time role bootstrap for vaults upgraded from v1 (which used the external
        /// troves AccessControl). Callable only while roles are uninitialised, by an account that
        /// holds DEFAULT_ADMIN in the v1 AccessControl. Seeds GOVERNANCE_ADMIN/SECURITY_ADMIN
        /// with `governance_admin` and enables delayed upgrades with `upgrade_delay` (> 0).
        fn initialize_roles_from_v1(
            ref self: ContractState,
            governance_admin: ContractAddress,
            upgrade_delay: u64,
            init_values: InitValues
        ) {
            let legacy = self.access_control.read();
            let legacy_felt: felt252 = legacy.into();
            assert(legacy_felt != 0, 'no v1 access control');
            assert(
                IAccessControlDispatcher { contract_address: legacy }
                    .has_role(0, get_caller_address()),
                'not v1 admin'
            );
            assert(upgrade_delay > 0, 'invalid upgrade delay');
            assert(init_values.init0 != 0 && init_values.init1 != 0, 'invalid init values');
            // reverts if already initialised
            self.roles.initialize(:governance_admin);
            self.replaceability.initialize(:upgrade_delay);
            // v1 had neither: without init values a re-emptied vault could never be deposited
            // into again, and without dead shares supply can return to 0
            self.init_values.write(init_values);
            let this = get_contract_address();
            if self.erc20.balance_of(this) == 0 {
                self.erc20.mint(this, DEAD_SHARES);
            }
        }

        /// @notice Minimum delay the governor/admin timelock must enforce. Must stay > 0.
        fn set_min_timelock_delay(ref self: ContractState, min_delay: u64) {
            self.roles.only_app_governor();
            self._assert_timelocked_caller();
            assert(min_delay > 0, 'invalid min timelock delay');
            self.min_timelock_delay.write(min_delay);
            self.emit(MinTimelockDelayUpdated { min_delay });
        }

        fn get_init_values(self: @ContractState) -> InitValues {
            self.init_values.read()
        }

        fn get_min_timelock_delay(self: @ContractState) -> u64 {
            self.min_timelock_delay.read()
        }

        /// @notice Allow (delay_selector != 0) or remove (0) a timelock class. The caller's own
        /// class must still be allowed afterwards, so the governor cannot lock itself out.
        fn set_timelock_class(ref self: ContractState, class_hash: ClassHash, delay_selector: felt252) {
            self.roles.only_app_governor();
            self._assert_timelocked_caller();
            self._set_timelock_class(class_hash, delay_selector);
            if self.min_timelock_delay.read() != 0 {
                let own = starknet::syscalls::get_class_hash_at_syscall(get_caller_address())
                    .unwrap_syscall();
                assert(self.allowed_timelock_classes.read(own) != 0, 'would lock out caller');
            }
        }

        fn get_timelock_class_selector(self: @ContractState, class_hash: ClassHash) -> felt252 {
            self.allowed_timelock_classes.read(class_hash)
        }

        fn get_rebalance_settings(self: @ContractState) -> RebalanceSettings {
            self.rebalance_settings.read()
        }

        fn get_last_rebalance_timestamp(self: @ContractState) -> u64 {
            self.last_rebalance_ts.read()
        }
    }

    #[generate_trait]
    pub impl InternalImpl of InternalTrait {
        /// The caller (already role-checked) must be a timelock (OZ TimelockController ABI)
        /// whose min delay is at least `min_timelock_delay`. A speed bump, not a proof: a
        /// contract can fake get_min_delay, but it forces an explicit, reviewable setup.
        fn _assert_timelocked_caller(self: @ContractState) {
            let required = self.min_timelock_delay.read();
            if required == 0 {
                return;
            }
            let caller = get_caller_address();
            let class_hash = starknet::syscalls::get_class_hash_at_syscall(caller).unwrap_syscall();
            let selector = self.allowed_timelock_classes.read(class_hash);
            assert(selector != 0, 'timelock class not allowed');
            let res = starknet::syscalls::call_contract_syscall(caller, selector, array![].span())
                .unwrap_syscall();
            let delay: u64 = (*res.at(0)).try_into().expect('invalid timelock delay');
            assert(delay >= required, 'timelock delay too short');
        }

        fn _set_timelock_class(ref self: ContractState, class_hash: ClassHash, delay_selector: felt252) {
            let ch: felt252 = class_hash.into();
            assert(ch != 0, 'invalid class hash');
            self.allowed_timelock_classes.write(class_hash, delay_selector);
            self.emit(TimelockClassUpdated { class_hash, delay_selector });
        }

        fn _assert_valid_fee_settings(self: @ContractState, fee_settings: FeeSettings) {
            assert(fee_settings.fee_bps <= MAX_FEE_BPS, 'invalid fee bps');
            let collector: felt252 = fee_settings.fee_collector.into();
            assert(collector != 0, 'invalid fee collector');
        }

        fn _is_paused(self: @ContractState) -> bool {
            self.pausable.is_paused()
        }

        fn _checked_rebalance_swap(
            ref self: ContractState, swap_params: AvnuMultiRouteSwap, settings: RebalanceSettings
        ) {
            let pool = self.managed_pools[0].read();
            let token0 = pool.pool_key.token0;
            let token1 = pool.pool_key.token1;
            let from = swap_params.token_from_address;
            let to = swap_params.token_to_address;
            assert(
                (from == token0 && to == token1) || (from == token1 && to == token0),
                'invalid swap tokens'
            );
            let amount_in = swap_params.token_from_amount;
            let max_in = if from == token0 { settings.max_swap_amount0 } else { settings.max_swap_amount1 };
            assert(amount_in <= max_in, 'swap amount too high');

            self._oracle_checked_swap(swap_params, settings.max_slippage_bps);
        }

        /// Validated oracle price (USD, 1e18). Reverts on stale / too-few-sources / zero price.
        fn _price(self: @ContractState, token: ContractAddress) -> u256 {
            let p = IVesuOracleDispatcher { contract_address: self.oracle.read() }.price(token);
            assert(p.is_valid && p.value > 0, 'oracle price invalid');
            p.value
        }

        /// AVNU swap followed by an unconditional oracle check: value_out >= value_in * (1 - bps).
        fn _oracle_checked_swap(
            ref self: ContractState, swap_params: AvnuMultiRouteSwap, max_slippage_bps: u32
        ) -> u256 {
            let from = swap_params.token_from_address;
            let to = swap_params.token_to_address;
            let amount_in = swap_params.token_from_amount;
            let amount_out = swap_params.swap();

            let value_in = mul_div(
                amount_in, self._price(from), pow::ten_pow(ERC20Helper::decimals(from).into())
            );
            let value_out = mul_div(
                amount_out, self._price(to), pow::ten_pow(ERC20Helper::decimals(to).into())
            );
            assert(
                value_out * 10000 >= value_in * (10000 - max_slippage_bps.into()),
                'Swap:: Slippage too high'
            );
            amount_out
        }

        /// Oracle-implied Ekubo tick for pool_key (token1 per token0, raw units).
        fn _oracle_tick(self: @ContractState, pool_key: PoolKey) -> i129 {
            let p0 = self._price(pool_key.token0);
            let p1 = self._price(pool_key.token1);
            self._tick_from_prices(pool_key, p0, p1)
        }

        /// Non-reverting variant: None if either price is invalid (stale / too few sources / 0).
        fn _try_oracle_tick(self: @ContractState, pool_key: PoolKey) -> Option<i129> {
            let oracle = IVesuOracleDispatcher { contract_address: self.oracle.read() };
            let a = oracle.price(pool_key.token0);
            let b = oracle.price(pool_key.token1);
            if !a.is_valid || !b.is_valid || a.value == 0 || b.value == 0 {
                return Option::None;
            }
            Option::Some(self._tick_from_prices(pool_key, a.value, b.value))
        }

        fn _tick_from_prices(self: @ContractState, pool_key: PoolKey, p0: u256, p1: u256) -> i129 {
            let dec0: u8 = ERC20Helper::decimals(pool_key.token0);
            let dec1: u8 = ERC20Helper::decimals(pool_key.token1);
            // ratio * 2^128 = p0 * 10^dec1 * 2^128 / (p1 * 10^dec0)   (512-bit intermediate)
            let ratio_x128 = mul_div(
                p0 * pow::ten_pow(dec1.into()), TWO_POW_128, p1 * pow::ten_pow(dec0.into())
            );
            assert(ratio_x128 > 0, 'oracle ratio underflow');
            // sqrt(ratio * 2^128) * 2^64 = sqrt(ratio) * 2^128
            let root: u128 = ratio_x128.sqrt();
            let sqrt_ratio: u256 = root.into() * TWO_POW_64;
            ekuboLibDispatcher().sqrt_ratio_to_tick(sqrt_ratio)
        }

        /// True when the pool's spot tick is within max_pool_tick_deviation of a valid oracle tick.
        fn _pool_near_oracle(self: @ContractState, pool_index: u64) -> bool {
            let pool = self.managed_pools[pool_index].read();
            match self._try_oracle_tick(pool.pool_key) {
                Option::Some(oracle_tick) => {
                    let pool_tick = self._get_pool_price(pool_index).tick;
                    tick_distance(pool_tick, oracle_tick)
                        <= self.rebalance_settings.read().max_pool_tick_deviation
                },
                Option::None => false,
            }
        }

        fn _handle_fees(ref self: ContractState, pool_index: u64) {
            let pool = self.managed_pools[pool_index].read();
            if pool.nft_id == 0 {
                return;
            }
            let this: ContractAddress = get_contract_address();
            let positions_disp = self.ekubo_positions_contract.read();
            let token_info = positions_disp.get_token_info(pool.nft_id, pool.pool_key, pool.bounds);

            let (fee0, fee1) = self._collect_strat_fee(pool);
            if (fee0 == 0 && fee1 == 0) {
                return;
            }

            // Re-deposit only at a pool price close to the oracle (adding liquidity at a
            // manipulated price loses value); otherwise, or if the oracle is invalid, the fees stay
            // idle (still counted in the share price) until the next rebalance.
            let deposit = self._pool_near_oracle(pool_index);
            if deposit {
                // @dev may leave some unused balances in the contract (redeployed on rebalance)
                self._ekubo_deposit(this, fee0, fee1, this, pool_index, 0);
            }

            self
                .emit(
                    HandleFees {
                        token0_addr: pool.pool_key.token0,
                        token0_origin_bal: token_info.amount0.into(),
                        token0_deposited: if deposit { fee0 } else { 0 },
                        token1_addr: pool.pool_key.token1,
                        token1_origin_bal: token_info.amount1.into(),
                        token1_deposited: if deposit { fee1 } else { 0 },
                        pool_info: pool
                    }
                );
        }

        fn _idle_balances(self: @ContractState) -> (u256, u256) {
            let pool_key = self.managed_pools[0].read().pool_key;
            let this = get_contract_address();
            (
                ERC20Helper::balanceOf(pool_key.token0, this),
                ERC20Helper::balanceOf(pool_key.token1, this)
            )
        }

        fn _liquidity_to_amounts_down(self: @ContractState, pool_index: u64, liquidity: u256) -> (u256, u256) {
            if liquidity == 0 {
                return (0, 0);
            }
            let price = self._get_pool_price(pool_index).sqrt_ratio;
            let sqrt = self.sqrt_values[pool_index].read();
            let delta = ekuboLibDispatcher()
                .liquidity_delta_to_amount_delta(
                    price,
                    i129 { mag: liquidity.try_into().unwrap(), sign: true },
                    sqrt.sqrt_lower,
                    sqrt.sqrt_upper
                );
            (delta.amount0.mag.into(), delta.amount1.mag.into())
        }

        fn _deposit(
            ref self: ContractState,
            amount0: u256,
            amount1: u256,
            receiver: ContractAddress,
            min_shares: u256
        ) -> u256 {
            self.reng.start();
            self.pausable.assert_not_paused();
            let caller: ContractAddress = get_caller_address();
            assert(amount0 > 0 || amount1 > 0, 'amounts cannot be zero');
            let (shares, paid0, paid1) = self._process_deposit(amount0, amount1);
            assert(shares >= min_shares, 'insufficient shares minted');
            self.erc20.mint(receiver, shares);
            self
                .emit(
                    Deposit {
                        sender: caller, owner: receiver, shares: shares, amount0: paid0, amount1: paid1
                    }
                );
            self.reng.end();
            shares
        }

        fn _withdraw(
            ref self: ContractState,
            shares: u256,
            receiver: ContractAddress,
            min_amount0: u256,
            min_amount1: u256
        ) -> MyPositions {
            self.reng.start();
            let caller = get_caller_address();
            assert(shares > 0, 'zero shares');
            let max_shares = self.balance_of(caller);
            assert(shares <= max_shares, 'insufficient shares');

            // Collect pending fees (minus strategy fee) into idle balances so the exiting user gets
            // their share. Deliberately no Ekubo re-deposit here: exits must not depend on adding
            // liquidity succeeding, and collecting also avoids Ekubo's MUST_COLLECT_FEES revert
            // when a range's liquidity is fully burnt. Works the same while paused.
            let n_pools = self.managed_pools.len();
            let mut i = 0;
            while i != n_pools {
                let pool = self.managed_pools[i].read();
                if pool.nft_id != 0 {
                    self._collect_strat_fee(pool);
                }
                i += 1;
            }

            // liquidity per pool and idle share computed before burning shares
            let supply = self.total_supply();
            let (idle0, idle1) = self._idle_balances();
            let idle_share0 = idle0 * shares / supply;
            let idle_share1 = idle1 * shares / supply;
            let mut liquidities = ArrayTrait::<u256>::new();
            i = 0;
            while i != n_pools {
                liquidities.append(self._convert_to_liquidity(shares, i, supply));
                i += 1;
            }

            // burn shares
            self.erc20.burn(caller, shares);

            let mut positions = ArrayTrait::<MyPosition>::new();
            let mut total_amount0: u256 = 0;
            let mut total_amount1: u256 = 0;
            i = 0;
            while i != n_pools {
                let liquidity = *liquidities.at(i.try_into().unwrap());
                if liquidity == 0 {
                    // empty range (or never minted): nothing to withdraw
                    positions.append(MyPosition { liquidity: 0, amount0: 0, amount1: 0 });
                    i += 1;
                    continue;
                }
                // actual amounts received from Ekubo (net of Ekubo withdrawal fee)
                let (amt0, amt1) = self._withdraw_position(liquidity, i);
                positions.append(MyPosition { liquidity, amount0: amt0.into(), amount1: amt1.into() });
                total_amount0 += amt0.into();
                total_amount1 += amt1.into();
                i += 1;
            }

            total_amount0 += idle_share0;
            total_amount1 += idle_share1;

            assert(total_amount0 >= min_amount0, 'insufficient amount0');
            assert(total_amount1 >= min_amount1, 'insufficient amount1');

            // transfer proceeds to receiver
            let pool_key = self.managed_pools[0].read().pool_key;
            if total_amount0 > 0 {
                ERC20Helper::transfer(pool_key.token0, receiver, total_amount0);
            }
            if total_amount1 > 0 {
                ERC20Helper::transfer(pool_key.token1, receiver, total_amount1);
            }

            self
                .emit(
                    Withdraw {
                        sender: caller,
                        receiver,
                        owner: caller,
                        shares: shares,
                        amount0: total_amount0,
                        amount1: total_amount1
                    }
                );
            self.reng.end();
            MyPositions { positions, total_amount0, total_amount1 }
        }

        fn get_sqrt_lower_upper(ref self: ContractState, bounds: Bounds) -> (u256, u256) {
            let sqrt_lower = ekuboLibDispatcher().tick_to_sqrt_ratio(bounds.lower);
            let sqrt_upper = ekuboLibDispatcher().tick_to_sqrt_ratio(bounds.upper);
            (sqrt_lower, sqrt_upper)
        }

        fn _create_sqrt_values(ref self: ContractState, bounds: Bounds) -> SqrtValues {
            let (sqrt_lower, sqrt_upper) = self.get_sqrt_lower_upper(bounds);
            SqrtValues { sqrt_lower: sqrt_lower, sqrt_upper: sqrt_upper }
        }

        fn _is_valid_token_pair(self: @ContractState, pool_key1: PoolKey, pool_key2: PoolKey) -> bool {
            let is_token0_equal = pool_key1.token0 == pool_key2.token0;
            let is_token1_equal = pool_key1.token1 == pool_key2.token1;
            return is_token0_equal && is_token1_equal;
        }

        fn _ekubo_harvest(ref self: ContractState, rewardsContract: ContractAddress, claim: Claim, proof: Span<felt252>) -> (ContractAddress, u256) {
            let distributor: IEkuboDistributorDispatcher = IEkuboDistributorDispatcher {
                contract_address: rewardsContract
            };
            let rewardToken: ContractAddress = distributor.get_token().contract_address;
 
            if (proof.is_empty()) {
                return (rewardToken, 0);
            }
    
            let this = get_contract_address();
            let pre_bal = ERC20Helper::balanceOf(rewardToken, this);
            distributor.claim(claim, proof);
            let post_bal = ERC20Helper::balanceOf(rewardToken, this);
    
            // claim may not be exactly as requested, so we do bal diff check
            let amount = (post_bal - pre_bal);
            assert(amount > 0, 'No harvest');

            (rewardToken, amount)
        }

        fn _find_pool_index(
            self: @ContractState,
            pool_key: PoolKey,
            bounds: Bounds
        ) -> Option<u64> {
            let mut i = 0;
            while i != self.managed_pools.len() {
                let pool = self.managed_pools[i].read();
                if pool.pool_key == pool_key
                    && pool.bounds == bounds
                {
                    return Option::Some(i);
                }
                i += 1;
            }
            Option::None
        }

        fn _modify_pool(ref self: ContractState, pool: ManagedPool, is_add: bool) {
            if is_add {
                // Add pool logic
                assert_valid_bounds(pool.pool_key, pool.bounds);
                // a pre-existing position NFT must belong to the vault: a foreign NFT would be
                // counted in share pricing and make every withdraw revert (Ekubo auth check)
                if pool.nft_id != 0 {
                    let owner = IEkuboNFTDispatcher { contract_address: self.ekubo_positions_nft.read() }
                        .ownerOf(pool.nft_id.into());
                    assert(owner == get_contract_address(), 'nft not owned by vault');
                }
                // Check pool doesn't already exist
                let existing_index = self._find_pool_index(pool.pool_key, pool.bounds);
                assert(existing_index.is_none(), 'pool already exists');

                // Validate tokens match first pool
                if self.managed_pools.len() > 0 {
                    let pool1 = self.managed_pools[0].read();
                    assert(self._is_valid_token_pair(pool1.pool_key, pool.pool_key), 'invalid token pair');
                }

                // Add pool and calculate sqrt values
                self.managed_pools.push(pool);
                self.sqrt_values.push(self._create_sqrt_values(pool.bounds));

                // Emit event
                self.emit(
                    PoolUpdated {
                        pool_key: pool.pool_key,
                        bounds: pool.bounds,
                        pool_index: self.managed_pools.len() - 1,
                        is_add: true
                    }
                );
            } else {
                // Remove pool logic
                // Find pool index
                let pool_index_opt = self._find_pool_index(pool.pool_key, pool.bounds);
                assert(pool_index_opt.is_some(), 'pool does not exist');
                let pool_index = pool_index_opt.unwrap();

                // Check liquidity is zero
                let position_liquidity = self.total_liquidity_per_pool(pool_index);
                assert(position_liquidity == 0, 'liquidity must be zero');

                // Swap with last element
                let last_index = self.managed_pools.len() - 1;
                let last_pool = self.managed_pools[last_index].read();
                let last_sqrt = self.sqrt_values[last_index].read();
                if pool_index != last_index {
                    self.managed_pools[pool_index].write(last_pool);
                    self.sqrt_values[pool_index].write(last_sqrt);

                    self.emit(
                        PoolUpdated {
                            pool_key: pool.pool_key,
                            bounds: pool.bounds,
                            pool_index: pool_index,
                            is_add: false
                        }
                    );

                    // since its a swap, we need to emit the addition of the last pool
                    // and removal event below
                    self.emit(
                        PoolUpdated {
                            pool_key: last_pool.pool_key,
                            bounds: last_pool.bounds,
                            pool_index: pool_index,
                            is_add: true
                        }
                    );
                }

                // Remove last element
                self.managed_pools.pop().unwrap();
                self.sqrt_values.pop().unwrap();

                // emit removal of last pool
                self.emit(
                    PoolUpdated {
                        pool_key: last_pool.pool_key,
                        bounds: last_pool.bounds,
                        pool_index: last_index,
                        is_add: false
                    }
                );
            }
        }

        fn _set_pool_data(ref self: ContractState, field: ManagedPoolField, pool_index: u64) {
            let curr_pool = self.managed_pools[pool_index].read();
            let mut updated = curr_pool;
            match field {
                ManagedPoolField::Bounds(bounds) => {
                    updated.bounds = bounds;
                },
                ManagedPoolField::NftId(nft_id) => {
                    updated.nft_id = nft_id;
                },
            };
            self.managed_pools[pool_index].write(updated);
        }

        fn _get_range_amounts(self: @ContractState, pool: ManagedPool) -> (u128, u128, u128) {
            let positions_disp = self.ekubo_positions_contract.read();
            if pool.nft_id == 0 {
                return (0, 0, 0);
            }
            let pool_info = positions_disp.get_token_info(pool.nft_id, pool.pool_key, pool.bounds);
            let range_amount0 = pool_info.amount0;
            let range_amount1 = pool_info.amount1;
            let range_liq = pool_info.liquidity;

            (range_amount0, range_amount1, range_liq)
        }

        fn _pay_ekubo(
            ref self: ContractState, sender: ContractAddress, token: ContractAddress, amount: u256
        ) {
            let this = get_contract_address();
            let positions_disp = self.ekubo_positions_contract.read();
            if (this == sender) {
                ERC20Helper::transfer(token, positions_disp.contract_address, amount);
            } else {
                ERC20Helper::transfer_from(token, sender, positions_disp.contract_address, amount);
            }
        }

        fn _get_pool_price(self: @ContractState, pool_index: u64) -> PoolPrice {
            let disp = self.ekubo_positions_contract.read();
            let pool = self.managed_pools[pool_index].read();
            return disp.get_pool_price(pool.pool_key);
        }


        fn _calculate_liquidity_delta(
            self: @ContractState,
            pool_index: u64,
            liquidity: u256
        ) -> (i129, i129) {
            let current_sqrt_price = self._get_pool_price(pool_index).sqrt_ratio;
            let delta = ekuboLibDispatcher()
                .liquidity_delta_to_amount_delta(
                    current_sqrt_price,
                    i129 { mag: liquidity.try_into().unwrap(), sign: false },
                    self.sqrt_values[pool_index].read().sqrt_lower,
                    self.sqrt_values[pool_index].read().sqrt_upper
                );
            (delta.amount0, delta.amount1)
        }

        fn _calculate_initial_shares(
            self: @ContractState,
            amount0: u256,
            amount1: u256,
        ) -> u256 {
            let pool = self.managed_pools[0].read();
            let dec0 = ERC20Helper::decimals(pool.pool_key.token0);
            let dec1 = ERC20Helper::decimals(pool.pool_key.token1);
            let scale0: u256 = pow::ten_pow(18 - dec0.into());
            let scale1: u256 = pow::ten_pow(18 - dec1.into());

            // normalize incoming amounts
            let amount0_n = amount0 * scale0;
            let amount1_n = amount1 * scale1;

            let init = self.init_values.read();
            let shares0 = if init.init0 > 0 {
                amount0_n * SCALE_18 / init.init0
            } else { 0 };
            let shares1 = if init.init1 > 0 {
                amount1_n * SCALE_18 / init.init1
            } else { 0 };
            (shares0 + shares1) / 2
        }

        fn _withdraw_position(ref self: ContractState, liquidity: u256, pool_index: u64) -> (u128, u128) {
            let disp = self.ekubo_positions_contract.read();
            let pool = self.managed_pools[pool_index].read();
            let old_liq = self.total_liquidity_per_pool(pool_index);
            let (amount0, amount1) = disp
                .withdraw(
                    pool.nft_id,
                    pool.pool_key,
                    pool.bounds,
                    liquidity.try_into().unwrap(),
                    0x00,
                    0x00,
                    false
                );

            // @dev nft_id is intentionally kept when liquidity reaches 0: the NFT can be re-used
            // for any bounds, and resetting it bricked withdraw (Ekubo call on NFT 0) and
            // orphaned uncollected fees.
            let current_liq = self.total_liquidity_per_pool(pool_index);

            if (old_liq - current_liq).into() != liquidity {
                let diff: felt252 = old_liq.try_into().unwrap() - current_liq.try_into().unwrap();
                Errors::invalid_liquidity_removed(pool_index, diff);
            }

            self.emit(
                EkuboPositionUpdated {
                    nft_id: pool.nft_id,
                    pool_key: pool.pool_key,
                    bounds: pool.bounds,
                    amount0_delta: i129{ mag: amount0, sign: true },
                    amount1_delta: i129{ mag: amount1, sign: true },
                    liquidity_delta: i129{ mag: liquidity.try_into().unwrap(), sign: true }
                }
            );

            (amount0, amount1)
        }

        // @returns liquidity
        fn _ekubo_deposit(
            ref self: ContractState,
            sender: ContractAddress,
            amount0: u256,
            amount1: u256,
            receiver: ContractAddress,
            pool_index: u64,
            min_liquidity: u128
        ) {
            let pool = self.managed_pools[pool_index].read();
            let pool_key = pool.pool_key;
            let token0 = pool_key.token0;
            let token1 = pool_key.token1;
            let positions_disp = self.ekubo_positions_contract.read();

            // send funds to ekubo
            self._pay_ekubo(sender, token0, amount0);
            self._pay_ekubo(sender, token1, amount1);

            let mut initial_position = MyPosition {
                liquidity: 0,
                amount0: 0,
                amount1: 0
            };
  
            let mut nft_id = pool.nft_id;
            if nft_id == 0 {
                nft_id = IEkuboNFTDispatcher {
                    contract_address: self.ekubo_positions_nft.read()
                }
                    .get_next_token_id();
                self._set_pool_data(ManagedPoolField::NftId(nft_id), pool_index);
                positions_disp
                    .mint_and_deposit(pool.pool_key, pool.bounds, min_liquidity);
            } else {
                initial_position = self.get_position(pool_index);
                positions_disp
                    .deposit(nft_id, pool.pool_key, pool.bounds, min_liquidity);
            }
            
            // clear any unused tokens and send to receiver
            positions_disp.clear_minimum_to_recipient(token0, 0, receiver);
            positions_disp.clear_minimum_to_recipient(token1, 0, receiver);

            let final_position = self.get_position(pool_index);
            self.emit(
                EkuboPositionUpdated {
                    nft_id: nft_id,
                    pool_key: pool.pool_key,
                    bounds: pool.bounds,
                    amount0_delta: i129{ mag: (final_position.amount0 - initial_position.amount0).try_into().unwrap(), sign: false },
                    amount1_delta: i129{ mag: (final_position.amount1 - initial_position.amount1).try_into().unwrap(), sign: false },
                    liquidity_delta: i129{ mag: (final_position.liquidity - initial_position.liquidity).try_into().unwrap(), sign: false }
                }
            );
        }

        fn _collect_strat_fee(ref self: ContractState, pool: ManagedPool) -> (u256, u256) {
            // collect fees from ekubo positions
            let nft_id = pool.nft_id;
            if (nft_id == 0) {
                return (0, 0);
            }

            let pool_key = pool.pool_key;
            let bounds = pool.bounds;
            let token0 = pool_key.token0;
            let token1 = pool_key.token1;
            let (fee0, fee1) = self
                .ekubo_positions_contract
                .read()
                .collect_fees(nft_id, pool_key, bounds);

            let fee_settings = self.fee_settings.read();
            
            let bps =
            fee_settings.fee_bps;
            let collector = fee_settings.fee_collector;
            let fee_eth = (fee0.into() * bps) / 10000;
            let fee_wst_eth = (fee1.into() * bps) / 10000;

            // transfer to fee collector
            ERC20Helper::transfer(token0, collector, fee_eth);
            ERC20Helper::transfer(token1, collector, fee_wst_eth);

            // return remaining amounts
            (fee0.into() - fee_eth, fee1.into() - fee_wst_eth)
        }   

        /// @returns (shares minted to the user, amount0 paid, amount1 paid)
        fn _process_deposit(
            ref self: ContractState,
            amount0: u256,
            amount1: u256,
        ) -> (u256, u256, u256) {
            let caller = get_caller_address();
            let this = get_contract_address();
            let pool0 = self.managed_pools[0].read();
            assert(amount0 > 0 || amount1 > 0, 'zero deposit');

            let total_supply = self.total_supply();
            if (total_supply == 0) {
                let shares = self._calculate_initial_shares(amount0, amount1);
                assert(shares > DEAD_SHARES, 'zero shares');
                // funds stay idle until the first rebalance
                ERC20Helper::transfer_from(pool0.pool_key.token0, caller, this, amount0);
                ERC20Helper::transfer_from(pool0.pool_key.token1, caller, this, amount1);
                // permanently locked in the vault
                self.erc20.mint(this, DEAD_SHARES);
                return (shares - DEAD_SHARES, amount0, amount1);
            }

            // compound pending fees first so the share price is up to date
            let mut i = 0;
            while i != self.managed_pools.len() {
                self._handle_fees(i);
                i += 1;
            }

            let SharesInfo { shares, user_level_positions, vault_level_positions: _ } =
                self._convert_to_shares(amount0, amount1);
            assert(shares > 0, 'zero shares');
            // never pull more than the user offered
            assert(user_level_positions.total_amount0 <= amount0, 'deposit exceeds amount0');
            assert(user_level_positions.total_amount1 <= amount1, 'deposit exceeds amount1');

            // 1) per-range: the user's own pro-rata liquidity
            let mut range0: u256 = 0;
            let mut range1: u256 = 0;
            i = 0;
            while i != self.managed_pools.len() {
                let position = *user_level_positions.positions.at(i.try_into().unwrap());
                if position.liquidity == 0 {
                    i += 1;
                    continue;
                }
                self._ekubo_deposit(
                    caller,
                    position.amount0,
                    position.amount1,
                    caller, // any unused dust goes back to the user
                    i,
                    position.liquidity.try_into().unwrap() // shares must be fully backed
                );
                range0 += position.amount0;
                range1 += position.amount1;
                i += 1;
            }

            // 2) pro-rata share of idle balances, kept idle in the vault
            let idle0 = user_level_positions.total_amount0 - range0;
            let idle1 = user_level_positions.total_amount1 - range1;
            if idle0 > 0 {
                ERC20Helper::transfer_from(pool0.pool_key.token0, caller, this, idle0);
            }
            if idle1 > 0 {
                ERC20Helper::transfer_from(pool0.pool_key.token1, caller, this, idle1);
            }

            (shares, user_level_positions.total_amount0, user_level_positions.total_amount1)
        }

        /// @notice Shares for (at most) amount0/amount1, pro-rata to the vault's total holdings.
        /// @dev total = Σ range amounts + idle balances. shares = min_i(amount_i * S / total_i)
        ///      (with a small rounding margin). The user then provides, for each range, the same
        ///      fraction of its liquidity, plus the same fraction of idle balances. This is
        ///      symmetric with withdraw and resistant to pool-price manipulation (liquidity
        ///      fractions, not prices, decide ownership).
        ///      user_level_positions.total_* = total tokens pulled (ranges + idle);
        ///      vault_level_positions.total_* = vault totals including idle.
        fn _convert_to_shares(self: @ContractState, amount0: u256, amount1: u256) -> SharesInfo {
            let total_supply = self.total_supply();
            let n_pools = self.managed_pools.len();
            let mut ranges = ArrayTrait::<MyPosition>::new();
            let mut vault_total0: u256 = 0;
            let mut vault_total1: u256 = 0;
            let mut i = 0;
            while i != n_pools {
                let pool = self.managed_pools[i].read();
                let (r0, r1, rl) = self._get_range_amounts(pool);
                vault_total0 += r0.into();
                vault_total1 += r1.into();
                ranges.append(MyPosition { liquidity: rl.into(), amount0: r0.into(), amount1: r1.into() });
                i += 1;
            }
            let (idle0, idle1) = self._idle_balances();
            vault_total0 += idle0;
            vault_total1 += idle1;

            if (total_supply == 0) {
                return SharesInfo {
                    shares: self._calculate_initial_shares(amount0, amount1),
                    user_level_positions: MyPositions {
                        positions: ArrayTrait::<MyPosition>::new(),
                        total_amount0: amount0,
                        total_amount1: amount1,
                    },
                    vault_level_positions: MyPositions {
                        positions: ArrayTrait::<MyPosition>::new(),
                        total_amount0: vault_total0,
                        total_amount1: vault_total1,
                    },
                };
            }
            assert(vault_total0 > 0 || vault_total1 > 0, 'empty vault');

            // rounding margin per token: each range rounds up by <= 2 wei, idle by <= 1 wei
            let margin: u256 = 2 * n_pools.into() + 2;
            let mut shares: u256 = core::num::traits::Bounded::<u256>::MAX;
            if vault_total0 > 0 {
                let usable0 = if amount0 > margin { amount0 - margin } else { 0 };
                let s0 = mul_div(usable0, total_supply, vault_total0);
                if s0 < shares { shares = s0; }
            }
            if vault_total1 > 0 {
                let usable1 = if amount1 > margin { amount1 - margin } else { 0 };
                let s1 = mul_div(usable1, total_supply, vault_total1);
                if s1 < shares { shares = s1; }
            }

            // Rounding in the vault totals (positions are reported rounded down) is amplified by
            // shares / supply, which is huge when the vault holds only dust (e.g. after everyone
            // exited). If the required amounts overshoot what was offered, scale shares down
            // proportionally and recompute (converges in 1-2 steps).
            let (mut user_positions, mut user_total0, mut user_total1) = self
                ._user_amounts_for_shares(@ranges, idle0, idle1, shares, total_supply);
            let mut iter: u8 = 0;
            while (user_total0 > amount0 || user_total1 > amount1) && shares > 0 && iter != 4 {
                let mut scaled = shares;
                if user_total0 > amount0 {
                    scaled = mul_div(scaled, amount0, user_total0);
                }
                if user_total1 > amount1 {
                    let s1 = mul_div(shares, amount1, user_total1);
                    if s1 < scaled { scaled = s1; }
                }
                shares = if scaled > 0 { scaled - 1 } else { 0 };
                let (p, t0, t1) = self._user_amounts_for_shares(@ranges, idle0, idle1, shares, total_supply);
                user_positions = p;
                user_total0 = t0;
                user_total1 = t1;
                iter += 1;
            }

            SharesInfo {
                shares,
                user_level_positions: MyPositions {
                    positions: user_positions, total_amount0: user_total0, total_amount1: user_total1,
                },
                vault_level_positions: MyPositions {
                    positions: ranges, total_amount0: vault_total0, total_amount1: vault_total1,
                },
            }
        }

        /// Tokens a depositor must provide for `shares`: per range the pro-rata liquidity (amounts
        /// rounded up by Ekubo) plus the pro-rata idle balances (rounded up).
        fn _user_amounts_for_shares(
            self: @ContractState,
            ranges: @Array<MyPosition>,
            idle0: u256,
            idle1: u256,
            shares: u256,
            total_supply: u256
        ) -> (Array<MyPosition>, u256, u256) {
            let mut user_positions = ArrayTrait::<MyPosition>::new();
            let mut user_total0: u256 = 0;
            let mut user_total1: u256 = 0;
            let mut i: u64 = 0;
            while i != self.managed_pools.len() {
                let range = *ranges.at(i.try_into().unwrap());
                let liq = mul_div(range.liquidity, shares, total_supply);
                let (a0, a1) = if liq == 0 { (0, 0) } else { self.get_amount_delta(i, liq) };
                user_positions.append(MyPosition { liquidity: liq, amount0: a0, amount1: a1 });
                user_total0 += a0;
                user_total1 += a1;
                i += 1;
            }
            user_total0 += ceil_div(idle0 * shares, total_supply);
            user_total1 += ceil_div(idle1 * shares, total_supply);
            (user_positions, user_total0, user_total1)
        }

        fn _convert_to_liquidity(self: @ContractState, shares: u256, pool_index: u64, supply: u256) -> u256 {
            if (supply == 0) {
                return supply;
            }

            let total_liquidity = self.total_liquidity_per_pool(pool_index);
            return (shares * total_liquidity) / supply;
        }
    }
}
