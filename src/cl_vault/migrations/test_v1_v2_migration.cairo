#[cfg(test)]
mod test_v1_v2_migration {
    use starknet::{ContractAddress, get_contract_address};
    use snforge_std::{
        declare, ContractClassTrait, start_cheat_caller_address, stop_cheat_caller_address,
        DeclareResultTrait,
    };
    use troves_clvaults::cl_vault::interface::{IClVaultDispatcher, IClVaultDispatcherTrait};
    use openzeppelin::interfaces::accesscontrol::{
        IAccessControlDispatcher, IAccessControlDispatcherTrait,
    };
    use starkware_utils::components::roles::interface::{IRolesDispatcher, IRolesDispatcherTrait};
    use troves_clvaults::cl_vault::migrations::interface::{
        IMigrationDispatcher, IMigrationDispatcherTrait,
    };
    use troves_clvaults::cl_vault::migrations::v1_v2::RoleHolders;

    // v1 (troves CommonComp) view, only needed to find the v1 AccessControl
    #[starknet::interface]
    trait ILegacyCommon<T> {
        fn access_control(self: @T) -> ContractAddress;
    }

    // Troves v1 Ekubo xSTRK/STRK CL vault
    const OLD_VAULT_ADDRESS: ContractAddress =
        0x01f083b98674bc21effee29ef443a00c7b9a500fd92cf30341a3da12c73f2324
        .try_into()
        .unwrap();
    // DEFAULT_ADMIN of the v1 AccessControl (from the v1 deployment)
    const V1_ADMIN: ContractAddress =
        0x0613a26e199f9bafa9418567f4ef0d78e9496a8d6aab15fba718a2ec7f2f2f69
        .try_into()
        .unwrap();

    fn a(x: felt252) -> ContractAddress {
        x.try_into().unwrap()
    }

    fn holders() -> RoleHolders {
        RoleHolders {
            governance_admin: a(0x7001),
            app_role_admin: a(0x7001),
            app_governor: a(0x7001),
            operator: a(0x7002),
            upgrade_governor: a(0x7001),
            security_admin: a(0x7001),
            security_agent: a(0x7003),
            security_governor: a(0x7001),
        }
    }

    #[test]
    #[fork("mainnet_4707139")]
    fn test_v1_v2_migration() {
        let migration_class = declare("V1V2Migration").unwrap().contract_class();
        let owner: ContractAddress = 0x123.try_into().unwrap();
        let (migration_address, _) = migration_class
            .deploy(@array![owner.into()])
            .expect('Migration deploy failed');
        let migration = IMigrationDispatcher { contract_address: migration_address };
        let new_class_hash = *declare("ConcLiquidityVault").unwrap().contract_class().class_hash;

        // v1 admin grants DEFAULT_ADMIN (v1 upgrade + v2 role bootstrap) to the migration
        let legacy_ac = ILegacyCommonDispatcher { contract_address: OLD_VAULT_ADDRESS }
            .access_control();
        start_cheat_caller_address(legacy_ac, V1_ADMIN);
        IAccessControlDispatcher { contract_address: legacy_ac }.grant_role(0, migration_address);
        stop_cheat_caller_address(legacy_ac);

        start_cheat_caller_address(migration_address, owner);
        let h = holders();
        migration
            .upgrade_vault(
                OLD_VAULT_ADDRESS,
                new_class_hash,
                troves_clvaults::tests::utils::VESU_ORACLE(),
                86400,
                h,
            );
        stop_cheat_caller_address(migration_address);

        let vault = IClVaultDispatcher { contract_address: OLD_VAULT_ADDRESS };
        let roles = IRolesDispatcher { contract_address: OLD_VAULT_ADDRESS };
        assert(vault.get_fee_settings().fee_bps == 1000, 'invalid fee settings');
        assert(vault.get_managed_pools_len() == 1, 'no managed pools found');
        assert(vault.get_min_timelock_delay() == 86400, 'timelock delay');
        assert(vault.get_pool_settings(0).oracle == troves_clvaults::tests::utils::VESU_ORACLE(), 'oracle');
        let mu = vault.get_max_unused_balances_on_rebalance();
        assert(mu.token0 == 0 && mu.token1 == 0, 'max unused');

        // final holders
        assert(roles.is_governance_admin(h.governance_admin), 'gov admin');
        assert(roles.is_app_governor(h.app_governor), 'app governor');
        assert(roles.is_operator(h.operator), 'operator');
        assert(roles.is_upgrade_governor(h.upgrade_governor), 'upgrade governor');
        assert(roles.is_security_agent(h.security_agent), 'security agent');
        assert(roles.is_security_governor(h.security_governor), 'security governor');
        // migration kept no app powers
        assert(!roles.is_app_governor(migration_address), 'migration still app governor');
        assert(!roles.is_app_role_admin(migration_address), 'migration still role admin');

        // follow-up by the new governance/security admin: drop the migration's admin roles
        start_cheat_caller_address(OLD_VAULT_ADDRESS, h.governance_admin);
        roles.remove_governance_admin(migration_address);
        roles.remove_security_admin(migration_address);
        stop_cheat_caller_address(OLD_VAULT_ADDRESS);
        assert(!roles.is_governance_admin(migration_address), 'migration still gov admin');
        assert(!roles.is_security_admin(migration_address), 'migration still sec admin');
        let _ = get_contract_address();
    }
}
