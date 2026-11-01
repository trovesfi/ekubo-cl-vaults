//! Standard OpenZeppelin TimelockController (OZ 3.0 component, no customisation), deployable as
//! the vault governor. Its class hash is meant to be allowlisted in the vault with
//! delay_selector = selector!("get_min_delay"). The StarkWare alternative is MultiExecutor from
//! starkware-starknet-utils (same pinned commit), allowlisted with selector!("get_execution_delay").
#[starknet::contract]
pub mod TimelockController {
    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::governance::timelock::TimelockControllerComponent;
    use openzeppelin::introspection::src5::SRC5Component;
    use starknet::ContractAddress;

    component!(path: AccessControlComponent, storage: access_control, event: AccessControlEvent);
    component!(path: TimelockControllerComponent, storage: timelock, event: TimelockEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[abi(embed_v0)]
    impl TimelockMixinImpl = TimelockControllerComponent::TimelockMixinImpl<ContractState>;
    impl TimelockInternalImpl = TimelockControllerComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        access_control: AccessControlComponent::Storage,
        #[substorage(v0)]
        timelock: TimelockControllerComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        TimelockEvent: TimelockControllerComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        min_delay: u64,
        proposers: Span<ContractAddress>,
        executors: Span<ContractAddress>,
        admin: ContractAddress,
    ) {
        self.timelock.initializer(min_delay, proposers, executors, admin);
    }
}
