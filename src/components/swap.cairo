// AVNU multi-route swap wrapper. Adapted from trovesfi/troves-contracts@01ca8f5
// src/components/swap.cairo with the legacy (zkLend-style) oracle check removed: the vault
// always performs its own oracle check on the output (see ConcLiquidityVault::_oracle_checked_swap).
use starknet::{ContractAddress, get_contract_address};
use openzeppelin::interfaces::erc20::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use troves_clvaults::helpers::constants;

#[derive(Drop, Clone, Serde)]
pub struct Route {
    pub token_from: ContractAddress,
    pub token_to: ContractAddress,
    pub exchange_address: ContractAddress,
    pub percent: u128,
    pub additional_swap_params: Array<felt252>,
}

#[starknet::interface]
pub trait IAvnu<TContractState> {
    fn multi_route_swap(
        ref self: TContractState,
        token_from_address: ContractAddress,
        token_from_amount: u256,
        token_to_address: ContractAddress,
        token_to_amount: u256,
        token_to_min_amount: u256,
        beneficiary: ContractAddress,
        integrator_fee_amount_bps: u128,
        integrator_fee_recipient: ContractAddress,
        routes: Array<Route>,
    ) -> bool;
}

/// Same Serde layout as the troves-contracts struct (ABI-compatible for relayers).
#[derive(Drop, Clone, Serde)]
pub struct AvnuMultiRouteSwap {
    pub token_from_address: ContractAddress,
    pub token_from_amount: u256,
    pub token_to_address: ContractAddress,
    pub token_to_amount: u256,
    pub token_to_min_amount: u256,
    pub beneficiary: ContractAddress,
    pub integrator_fee_amount_bps: u128,
    pub integrator_fee_recipient: ContractAddress,
    pub routes: Array<Route>,
}

#[generate_trait]
pub impl AvnuMultiRouteSwapImpl of AvnuMultiRouteSwapTrait {
    /// Executes the swap with this contract as beneficiary; returns the measured amount received.
    fn swap(self: AvnuMultiRouteSwap) -> u256 {
        let this = get_contract_address();
        assert(self.integrator_fee_amount_bps == 0, 'require avnu fee bps 0');
        assert(self.beneficiary == this, 'invalid swap beneficiary');

        let to_token = ERC20ABIDispatcher { contract_address: self.token_to_address };
        let pre_bal = to_token.balanceOf(this);

        let avnu = constants::AVNU_EX();
        let approved = ERC20ABIDispatcher { contract_address: self.token_from_address }
            .approve(avnu, self.token_from_amount);
        assert(approved, 'Approval failed');
        let swapped = IAvnuDispatcher { contract_address: avnu }
            .multi_route_swap(
                self.token_from_address,
                self.token_from_amount,
                self.token_to_address,
                self.token_to_amount,
                self.token_to_min_amount,
                self.beneficiary,
                self.integrator_fee_amount_bps,
                self.integrator_fee_recipient,
                self.routes,
            );
        assert(swapped, 'Swap failed');

        let amount = to_token.balanceOf(this) - pre_bal;
        assert(amount > 0, 'invalid to amount');
        amount
    }
}
