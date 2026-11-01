use starknet::{ContractAddress, ClassHash};
use troves_clvaults::cl_vault::migrations::v1_v2::RoleHolders;
use troves_clvaults::cl_vault::interface::TimelockClass;

#[starknet::interface]
pub trait IMigration<TContractState> {
    fn upgrade_vault(
        ref self: TContractState,
        vault: ContractAddress,
        new_class_hash: ClassHash,
        oracle: ContractAddress,
        min_timelock_delay: u64,
        role_holders: RoleHolders,
        allowed_timelocks: Array<TimelockClass>
    );
}
