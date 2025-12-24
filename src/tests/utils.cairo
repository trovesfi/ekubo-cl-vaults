use snforge_std::{
    declare, ContractClassTrait, start_cheat_caller_address, stop_cheat_caller_address,
};
use snforge_std::{DeclareResultTrait};
use starknet::{ContractAddress, get_contract_address};
use troves_clvaults::interfaces::IEkuboDistributor::{IEkuboDistributorDispatcher};
use strkfarm_contracts::helpers::constants;
use strkfarm_contracts::helpers::ERC20Helper;
use strkfarm_contracts::helpers::pow;

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
