use snforge_std::{
    declare, ContractClassTrait, start_cheat_caller_address, stop_cheat_caller_address,
};
use snforge_std::{DeclareResultTrait, start_mock_call, test_address};
use starknet::{ContractAddress, get_contract_address};
use troves_clvaults::interfaces::IEkuboDistributor::{IEkuboDistributorDispatcher};
use troves_clvaults::helpers::constants;
use troves_clvaults::helpers::ERC20Helper;
use troves_clvaults::helpers::pow;

pub fn deploy_access_control() -> ContractAddress {
    let cls = declare("AccessControl").unwrap().contract_class();

    let this = get_contract_address();

    let mut calldata: Array<felt252> = array![this.into(), this.into(), this.into(), this.into(),];
    let (address, _) = cls.deploy(@calldata).expect('AC deploy failed');
    return address;
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
