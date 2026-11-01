use snforge_std::{
    declare, ContractClassTrait, start_cheat_caller_address, stop_cheat_caller_address,
};
use snforge_std::{DeclareResultTrait, start_mock_call, test_address, get_class_hash};
use starknet::{ContractAddress, get_contract_address};
use starkware_utils::components::roles::interface::{IRolesDispatcher, IRolesDispatcherTrait};
use troves_clvaults::helpers::constants;
use troves_clvaults::helpers::ERC20Helper;
use troves_clvaults::helpers::pow;

/// Test contract = governance admin + security admin (seeded by the vault constructor).
/// Give it every other role the tests exercise.
pub fn setup_roles(vault: ContractAddress) {
    let this = get_contract_address();
    let roles = IRolesDispatcher { contract_address: vault };
    roles.register_app_role_admin(this);
    roles.register_app_governor(this);
    roles.register_operator(this);
    roles.register_upgrade_governor(this);
    roles.register_security_agent(this);
    roles.register_security_governor(this);
}

pub fn load_strk(user: ContractAddress) {
    // binance address
    let source: ContractAddress = 0x0213c67ed78bc280887234fe5ed5e77272465317978ae86c25a71531d9332a2d.try_into().unwrap();
    start_cheat_caller_address(constants::STRK_ADDRESS(), source);
    ERC20Helper::transfer(constants::STRK_ADDRESS(), user, 10000 * pow::ten_pow(18));
    stop_cheat_caller_address(constants::STRK_ADDRESS());
}

/// Vesu v2 oracle on Starknet mainnet (vesuxyz/vesu-v2 deployment.json): Pragma-backed, with
/// per-asset staleness timeout and minimum-sources checks; xSTRK uses CONVERSION_XSTRK/USD.
pub fn VESU_ORACLE() -> ContractAddress {
    0xfe4bfb1b353ba51eb34dff963017f94af5a5cf8bdf3dfc191c504657f3c05.try_into().unwrap()
}

pub const TEST_TIMELOCK_DELAY: u64 = 86400;

/// Makes the test contract (holder of all roles) look like an OZ timelock with the given delay.
pub fn mock_timelock(delay: u64) {
    start_mock_call(test_address(), selector!("get_min_delay"), delay);
}

/// Constructor arg: allow the test contract's class as a timelock (delay via mocked get_min_delay).
pub fn test_timelock_classes() -> Array<troves_clvaults::cl_vault::interface::TimelockClass> {
    array![
        troves_clvaults::cl_vault::interface::TimelockClass {
            class_hash: get_class_hash(test_address()), delay_selector: selector!("get_min_delay"),
        },
    ]
}
