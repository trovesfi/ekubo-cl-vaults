use starknet::{ContractAddress, ClassHash};

#[starknet::interface]
pub trait IMigration<TContractState> {
    fn upgrade_vault(
        ref self: TContractState,
        vault: ContractAddress,
        new_class_hash: ClassHash
    );
}
