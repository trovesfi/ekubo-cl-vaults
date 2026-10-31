// ABI of the Vesu v2 oracle (vesuxyz/vesu-v2 src/oracle.cairo, IOracle).
// The vault reuses that audited contract (Pragma spot/TWAP with per-asset staleness timeout and
// minimum number of sources) instead of a bespoke price check. `value` is USD scaled by 1e18;
// `is_valid` is false when the price is stale, has too few sources, or is zero.
use starknet::ContractAddress;

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct AssetPrice {
    pub value: u256,
    pub is_valid: bool,
}

#[starknet::interface]
pub trait IVesuOracle<TContractState> {
    fn price(self: @TContractState, asset: ContractAddress) -> AssetPrice;
}
