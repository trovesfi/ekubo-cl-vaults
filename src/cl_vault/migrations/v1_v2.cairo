use troves_clvaults::interfaces::IEkuboCore::{Bounds, PoolKey, PositionKey};
use troves_clvaults::ekubo::types::position::Position;
use starknet::ContractAddress;

/// Final role holders after migration (StarkWare roles). Recommended: timelock for
/// governance_admin / app_role_admin / app_governor / upgrade_governor / security_admin /
/// security_governor; guardian multisig for security_agent; relayer key for operator.
#[derive(Drop, Copy, Serde)]
pub struct RoleHolders {
    pub governance_admin: ContractAddress,
    pub app_role_admin: ContractAddress,
    pub app_governor: ContractAddress,
    pub operator: ContractAddress,
    pub upgrade_governor: ContractAddress,
    pub security_admin: ContractAddress,
    pub security_agent: ContractAddress,
    pub security_governor: ContractAddress,
}

#[derive(Drop, Copy, Serde, starknet::Store, starknet::Event)]
pub struct FeeSettings {
    pub fee_bps: u256,
    pub fee_collector: ContractAddress
}

#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct ClSettings {
    pub ekubo_positions_contract: ContractAddress,
    pub bounds_settings: Bounds,
    pub pool_key: PoolKey,
    pub ekubo_positions_nft: ContractAddress,
    pub contract_nft_id: u64, // NFT position id of Ekubo position
    pub ekubo_core: ContractAddress,
    pub oracle: ContractAddress,
    pub fee_settings: FeeSettings,
}

#[starknet::interface]
pub trait IClVaultV1<TContractState> {
    // returns shares
    fn total_liquidity(self: @TContractState) -> u256;
    fn get_position_key(self: @TContractState) -> PositionKey;
    fn get_position(self: @TContractState) -> Position;
    fn get_settings(self: @TContractState) -> ClSettings;
}

#[starknet::contract]
mod V1V2Migration {
    use starknet::{ContractAddress, get_caller_address, ClassHash};
    use openzeppelin::interfaces::upgrades::{IUpgradeableDispatcher, IUpgradeableDispatcherTrait};
    use starkware_utils::components::roles::interface::{IRolesDispatcher, IRolesDispatcherTrait};
    use starknet::get_contract_address;
    use super::RoleHolders;
    use troves_clvaults::cl_vault::interface::{
        IClVaultDispatcher, IClVaultDispatcherTrait, MaxUnusedBalances, RebalanceSettings, TimelockClass
    };
    use troves_clvaults::interfaces::IEkuboCore::{Bounds, PoolKey};
    use super::IClVaultV1DispatcherTrait;
    use troves_clvaults::cl_vault::interface::ManagedPool;

    #[storage]
    struct Storage {
        owner: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        MigrationExecuted: MigrationExecuted,
    }

    #[derive(Drop, starknet::Event)]
    struct MigrationExecuted {
        #[key]
        vault: ContractAddress,
        new_class_hash: ClassHash,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.owner.write(owner);
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _assert_owner(self: @ContractState) {
            let caller = get_caller_address();
            let owner = self.owner.read();
            assert(caller == owner, 'not owner');
        }
    }

    #[abi(embed_v0)]
    impl MigrationImpl of troves_clvaults::cl_vault::migrations::interface::IMigration<ContractState> {
        /// @notice Upgrades a vault from v1 to v2
        /// @dev This function upgrades the vault contract and initializes the new max_unused_balances_on_rebalance storage variable
        fn upgrade_vault(
            ref self: ContractState,
            vault: ContractAddress,
            new_class_hash: ClassHash,
            oracle: ContractAddress,
            min_timelock_delay: u64,
            role_holders: RoleHolders,
            allowed_timelocks: Array<TimelockClass>
        ) {
            self._assert_owner();

            // read old settings
            let old_vault_dispatcher = super::IClVaultV1Dispatcher { contract_address: vault };
            let current_settings = old_vault_dispatcher.get_settings();

            let old_liquidity = old_vault_dispatcher.total_liquidity();
            assert(old_liquidity > 0, 'old liquidity is 0');

            // 1) upgrade (v1 `upgrade`, gated by DEFAULT_ADMIN in the v1 AccessControl)
            IUpgradeableDispatcher { contract_address: vault }.upgrade(new_class_hash);
            let new_vault_dispatcher = IClVaultDispatcher { contract_address: vault };
            let roles = IRolesDispatcher { contract_address: vault };
            let this = get_contract_address();

            // 2) bootstrap StarkWare roles with this contract as temporary governance admin,
            //    and give it the app roles it needs to configure the vault
            new_vault_dispatcher.initialize_roles_from_v1(this, min_timelock_delay);
            roles.register_app_role_admin(this);
            roles.register_app_governor(this);

            // 3) configure (timelock guard is not enforced yet: min_timelock_delay == 0)
            new_vault_dispatcher
                .set_max_unused_balances_on_rebalance(MaxUnusedBalances { token0: 0, token1: 0 });
            // relayer guard-rails are new storage (zero = everything blocked): conservative defaults
            new_vault_dispatcher
                .set_rebalance_settings(
                    RebalanceSettings {
                        max_slippage_bps: 100,
                        max_pool_tick_deviation: 10000,
                        max_bounds_distance: 300000,
                        min_rebalance_interval: 0,
                        max_swap_amount0: core::num::traits::Bounded::<u256>::MAX,
                        max_swap_amount1: core::num::traits::Bounded::<u256>::MAX,
                    }
                );
            let fee_settings = new_vault_dispatcher.get_fee_settings();
            assert(fee_settings.fee_bps <= 10000, 'invalid fee settings');
            new_vault_dispatcher
                .add_pool(
                    ManagedPool {
                        pool_key: current_settings.pool_key,
                        bounds: current_settings.bounds_settings,
                        nft_id: current_settings.contract_nft_id,
                    }
                );
            // v1 used a zkLend-style oracle; v2 needs a Vesu v2 IOracle (validated prices)
            new_vault_dispatcher.set_oracle(oracle);
            assert(new_vault_dispatcher.get_managed_pools_len() == 1, 'no managed pools found');
            assert(new_vault_dispatcher.total_liquidity_per_pool(0) == old_liquidity, 'liquidity invalid');

            // 4) hand every role to its final holder
            roles.register_governance_admin(role_holders.governance_admin);
            roles.register_upgrade_governor(role_holders.upgrade_governor);
            roles.register_app_role_admin(role_holders.app_role_admin);
            roles.register_app_governor(role_holders.app_governor);
            roles.register_operator(role_holders.operator);
            roles.register_security_admin(role_holders.security_admin);
            roles.register_security_agent(role_holders.security_agent);
            roles.register_security_governor(role_holders.security_governor);

            // 5) from now on governor calls must come from an allowlisted timelock
            assert(allowed_timelocks.len() > 0, 'no timelock class');
            for t in allowed_timelocks.span() {
                new_vault_dispatcher.set_timelock_class(*t.class_hash, *t.delay_selector);
            };
            new_vault_dispatcher.set_min_timelock_delay(min_timelock_delay);
            assert(new_vault_dispatcher.get_min_timelock_delay() == min_timelock_delay, 'timelock delay not set');

            // 6) drop the app roles. GOVERNANCE_ADMIN / SECURITY_ADMIN cannot be self-renounced
            //    (StarkWare roles); the new governance/security admin must remove this contract
            //    with remove_governance_admin / remove_security_admin (it has no other entry point
            //    that can act on an already-migrated vault).
            roles.remove_app_governor(this);
            roles.remove_app_role_admin(this);

            self.emit(
                MigrationExecuted {
                    vault: vault,
                    new_class_hash: new_class_hash
                }
            );
        }
    }
}
