use troves_clvaults::interfaces::IEkuboCore::{Bounds, PoolKey, PositionKey};
use ekubo::types::position::Position;
use starknet::ContractAddress;

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
    use openzeppelin::upgrades::interface::{
        IUpgradeableDispatcher, IUpgradeableDispatcherTrait
    };
    use troves_clvaults::cl_vault::interface::{
        IClVaultDispatcher, IClVaultDispatcherTrait, MaxUnusedBalances
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
            new_class_hash: ClassHash
        ) {
            self._assert_owner();

            // read old settings
            let old_vault_dispatcher = super::IClVaultV1Dispatcher { contract_address: vault };
            let current_settings = old_vault_dispatcher.get_settings();

            let old_liquidity = old_vault_dispatcher.total_liquidity();
            assert(old_liquidity > 0, 'old liquidity is 0');

            // Upgrade the vault contract
            let upgradeable_dispatcher = IUpgradeableDispatcher { contract_address: vault };
            upgradeable_dispatcher.upgrade(new_class_hash);

            // Initialize the new storage variable max_unused_balances_on_rebalance
            // This is set to 0,0 (disabled by default) as per the v2 constructor
            let max_unused_balances = MaxUnusedBalances { token0: 0, token1: 0 };
            let new_vault_dispatcher = IClVaultDispatcher { contract_address: vault };
            new_vault_dispatcher.set_max_unused_balances_on_rebalance(max_unused_balances);

            // Verify the migration by checking that the new function exists and returns expected value
            let retrieved_max_unused = new_vault_dispatcher.get_max_unused_balances_on_rebalance();
            assert(
                retrieved_max_unused.token0 == 0 && retrieved_max_unused.token1 == 0,
                'max_unused_balances invalid'
            );

            // Verify other critical state variables are still accessible
            let fee_settings = new_vault_dispatcher.get_fee_settings();
            assert(fee_settings.fee_bps <= 10000, 'invalid fee settings');

            // add pool
            let pool_key = current_settings.pool_key;
            let bounds = current_settings.bounds_settings;
            let managed_pool = ManagedPool {
                pool_key: pool_key,
                bounds: bounds,
                nft_id: current_settings.contract_nft_id,
            };
            new_vault_dispatcher.add_pool(managed_pool);

            // Verify managed pools are still accessible
            let pools_len = new_vault_dispatcher.get_managed_pools_len();
            assert(pools_len == 1, 'no managed pools found');

            // assert liquidity at 0th position > 0
            let liquidity = new_vault_dispatcher.total_liquidity_per_pool(0);
            assert(liquidity == old_liquidity, 'liquidity invalid');

            self.emit(
                MigrationExecuted {
                    vault: vault,
                    new_class_hash: new_class_hash
                }
            );
        }
    }
}
