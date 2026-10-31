// Test-only mocks.
use starknet::ContractAddress;

#[starknet::interface]
pub trait IMockReentrantDistributor<T> {
    fn set_target(ref self: T, vault: ContractAddress, token: ContractAddress);
}

/// Pretends to be an Ekubo reward distributor; on claim() it re-enters the vault.
#[starknet::contract]
pub mod MockReentrantDistributor {
    use starknet::ContractAddress;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use openzeppelin::token::erc20::interface::IERC20Dispatcher;
    use troves_clvaults::cl_vault::interface::{IClVaultDispatcher, IClVaultDispatcherTrait};
    use troves_clvaults::interfaces::IEkuboDistributor::Claim;

    #[storage]
    struct Storage {
        vault: ContractAddress,
        token: ContractAddress,
    }

    #[abi(embed_v0)]
    impl MockImpl of super::IMockReentrantDistributor<ContractState> {
        fn set_target(ref self: ContractState, vault: ContractAddress, token: ContractAddress) {
            self.vault.write(vault);
            self.token.write(token);
        }
    }

    #[abi(embed_v0)]
    impl DistributorImpl of troves_clvaults::interfaces::IEkuboDistributor::IEkuboDistributor<
        ContractState,
    > {
        fn claim(ref self: ContractState, claim: Claim, proof: Span<felt252>) -> bool {
            IClVaultDispatcher { contract_address: self.vault.read() }.handle_fees(0);
            true
        }

        fn get_token(self: @ContractState) -> IERC20Dispatcher {
            IERC20Dispatcher { contract_address: self.token.read() }
        }
    }
}
