#[cfg(test)]
mod test_v1_v2_migration {
    use starknet::{ContractAddress, ClassHash, get_contract_address};
    use snforge_std::{
        declare, ContractClassTrait, start_cheat_caller_address, stop_cheat_caller_address,
        DeclareResultTrait
    };
    use troves_clvaults::cl_vault::interface::{
        IClVaultDispatcher, IClVaultDispatcherTrait, MaxUnusedBalances
    };
    use openzeppelin::upgrades::interface::{
        IUpgradeableDispatcher, IUpgradeableDispatcherTrait
    };
    use openzeppelin::utils::serde::SerializedAppend;
    use strkfarm_contracts::interfaces::common::ICommonDispatcher;
    use strkfarm_contracts::interfaces::common::ICommonDispatcherTrait;
    use openzeppelin::access::accesscontrol::interface::{
        IAccessControlDispatcher, IAccessControlDispatcherTrait
    };
    // Import the migration contract dispatcher
    use troves_clvaults::cl_vault::migrations::interface::{
        IMigrationDispatcher, IMigrationDispatcherTrait
    };

    // Old Ekubo xSTRK/STRK vault address
    const OLD_VAULT_ADDRESS: ContractAddress = 0x01f083b98674bc21effee29ef443a00c7b9a500fd92cf30341a3da12c73f2324.try_into().unwrap();

    #[test]
    #[fork("mainnet_4707139")]
    fn test_v1_v2_migration() {
        // Declare the migration contract
        let migration_class = declare("V1V2Migration").unwrap().contract_class();
        
        // Deploy migration contract with owner
        let owner: ContractAddress = 0x123.try_into().unwrap();
        let mut calldata: Array<felt252> = array![];
        calldata.append(owner.into());
        
        let (migration_address, _) = migration_class.deploy(@calldata).expect('Migration deploy failed');
        let migration = IMigrationDispatcher { contract_address: migration_address };

        // Set caller to owner
        start_cheat_caller_address(migration_address, owner);

        // Declare the v2 vault contract to get its class hash
        let v2_vault_class = declare("ConcLiquidityVault").unwrap();
        let new_class_hash = *v2_vault_class.contract_class().class_hash;

        // Note: This test uses the actual deployed old vault address
        // The migration will:
        // 1. Upgrade the vault to v2
        // 2. Initialize max_unused_balances_on_rebalance to (0, 0)
        // 3. Verify the migration was successful

        // give owner role to migration contract
        let common_dispatcher = ICommonDispatcher { contract_address: OLD_VAULT_ADDRESS };
        let access_control_address = common_dispatcher.access_control();
        let access_control = IAccessControlDispatcher { contract_address: access_control_address };
        let original_owner: ContractAddress = 0x0613a26e199f9bafa9418567f4ef0d78e9496a8d6aab15fba718a2ec7f2f2f69.try_into().unwrap();
        start_cheat_caller_address(access_control_address, original_owner);
        access_control.grant_role(0, migration_address); // default admin role
        access_control.grant_role(selector!("GOVERNOR"), migration_address); // governor role
        stop_cheat_caller_address(access_control_address);

        // Execute the migration
        migration.upgrade_vault(OLD_VAULT_ADDRESS, new_class_hash);

        // Verify the migration by checking the new function exists
        let vault_dispatcher = IClVaultDispatcher { contract_address: OLD_VAULT_ADDRESS };
        let max_unused = vault_dispatcher.get_max_unused_balances_on_rebalance();
        assert(max_unused.token0 == 0, 'max_unused.token0 should be 0');
        assert(max_unused.token1 == 0, 'max_unused.token1 should be 0');

        // Verify other state variables are still accessible
        let fee_settings = vault_dispatcher.get_fee_settings();
        assert(fee_settings.fee_bps == 1000, 'invalid fee settings');

        let pools_len = vault_dispatcher.get_managed_pools_len();
        assert(pools_len == 1, 'no managed pools found');

        stop_cheat_caller_address(migration_address);
    }
}

