pub mod Errors {
    pub fn invalid_liquidity_burn_at_index(pool_index: u64) -> felt252 {
        panic!("invalid liquidity burn at index {:?}", pool_index);
    }

    pub fn insufficient_amt0_at_index(pool_index: u64, required: u128, available: u256) -> felt252 {
        panic!("Rebalance: insufficient amt0 at index {:?}, required {:?}, available {:?}", pool_index, required, available);
    }

    pub fn insufficient_amt1_at_index(pool_index: u64, required: u128, available: u256) -> felt252 {
        panic!("Rebalance: insufficient amt1 at index {:?}, required {:?}, available {:?}", pool_index, required, available);
    }

    pub fn invalid_liquidity_removed(pool_index: u64, diff: felt252) -> felt252 {
        panic!("invalid liquidity removed for index {:?} and diff {:?}", pool_index, diff);
    }

    pub fn pool_0_has_no_liquidity() -> felt252 {
        panic!("pool 0 has no liquidity");
    }

    pub fn shares_mismatch(shares_for_other_pool: u256, shares: u256) -> felt252 {
        panic!("shares for other pool {:?} is not equal to shares {:?}", shares_for_other_pool, shares);
    }

    pub fn excessive_unused_token0(expected_max: u256, found: u256) -> felt252 {
        panic!("Rebalance: excessive unused token0, expected max {:?}, found {:?}", expected_max, found);
    }

    pub fn excessive_unused_token1(expected_max: u256, found: u256) -> felt252 {
        panic!("Rebalance: excessive unused token1, expected max {:?}, found {:?}", expected_max, found);
    }
}