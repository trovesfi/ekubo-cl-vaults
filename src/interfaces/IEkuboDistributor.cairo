use starknet::{ContractAddress};
use openzeppelin::interfaces::erc20::{IERC20Dispatcher};

#[derive(Drop, Copy, Serde)]
pub struct Claim {
    pub id: u64,
    pub claimee: ContractAddress,
    pub amount: u128,
}

#[starknet::interface]
pub trait IEkuboDistributor<TContractState> {
    fn claim(ref self: TContractState, claim: Claim, proof: Span<felt252>) -> bool;
    fn get_token(self: @TContractState) -> IERC20Dispatcher;
}
