//! Minimal Ekubo ABI types and interfaces used by the vault (replaces the unreachable
//! `EkuboProtocol/abis` dependency). Serde layouts and the i129 storage packing are identical to
//! Ekubo's, so calldata / return values / stored Bounds stay compatible with deployed contracts
//! and with vaults deployed from earlier builds.

pub mod types {
    pub mod i129 {
        use core::hash::{Hash, HashStateTrait};
        use starknet::storage_access::StorePacking;

        /// Signed integer: 128-bit magnitude + sign (sign with mag 0 is treated as +0).
        #[derive(Copy, Drop, Serde, Debug)]
        pub struct i129 {
            pub mag: u128,
            pub sign: bool,
        }

        fn is_negative(x: @i129) -> bool {
            *x.sign && *x.mag != 0
        }

        pub impl i129PartialEq of PartialEq<i129> {
            fn eq(lhs: @i129, rhs: @i129) -> bool {
                *lhs.mag == *rhs.mag && (*lhs.sign == *rhs.sign || *lhs.mag == 0)
            }
            fn ne(lhs: @i129, rhs: @i129) -> bool {
                !Self::eq(lhs, rhs)
            }
        }

        pub impl i129PartialOrd of PartialOrd<i129> {
            fn lt(lhs: i129, rhs: i129) -> bool {
                let ln = is_negative(@lhs);
                let rn = is_negative(@rhs);
                if ln != rn {
                    ln
                } else if ln {
                    lhs.mag > rhs.mag
                } else {
                    lhs.mag < rhs.mag
                }
            }
            fn le(lhs: i129, rhs: i129) -> bool {
                !Self::lt(rhs, lhs)
            }
            fn gt(lhs: i129, rhs: i129) -> bool {
                Self::lt(rhs, lhs)
            }
            fn ge(lhs: i129, rhs: i129) -> bool {
                !Self::lt(lhs, rhs)
            }
        }

        // Same as Ekubo: mag, plus 2**128 when negative
        pub impl HashI129<S, +HashStateTrait<S>, +Drop<S>> of Hash<i129, S> {
            fn update_state(state: S, value: i129) -> S {
                let mut hashable: felt252 = value.mag.into();
                if is_negative(@value) {
                    hashable += 0x100000000000000000000000000000000;
                }
                state.update(hashable)
            }
        }

        // Same as Ekubo: stored as a single felt, negative values as -mag
        pub impl i129StorePacking of StorePacking<i129, felt252> {
            fn pack(value: i129) -> felt252 {
                assert(value.mag < 0x80000000000000000000000000000000, 'i129_store_overflow');
                if value.sign {
                    -value.mag.into()
                } else {
                    value.mag.into()
                }
            }
            fn unpack(value: felt252) -> i129 {
                if value.into() >= 0x80000000000000000000000000000000_u256 {
                    let mag: u128 = (-value).try_into().unwrap();
                    i129 { mag, sign: mag != 0 }
                } else {
                    i129 { mag: value.try_into().unwrap(), sign: false }
                }
            }
        }
    }

    pub mod pool_price {
        use super::i129::i129;

        #[derive(Copy, Drop, Serde, PartialEq)]
        pub struct PoolPrice {
            pub sqrt_ratio: u256,
            pub tick: i129,
        }
    }

    pub mod position {
        #[derive(Copy, Drop, Serde, PartialEq, starknet::Store, Debug)]
        pub struct FeesPerLiquidity {
            pub value0: felt252,
            pub value1: felt252,
        }

        #[derive(Copy, Drop, Serde, starknet::Store)]
        pub struct Position {
            pub liquidity: u128,
            pub fees_per_liquidity_inside_last: FeesPerLiquidity,
        }
    }

    pub mod delta {
        use super::i129::i129;

        #[derive(Copy, Drop, Serde, PartialEq)]
        pub struct Delta {
            pub amount0: i129,
            pub amount1: i129,
        }
    }
}

pub mod interfaces {
    pub mod mathlib {
        use crate::ekubo::types::delta::Delta;
        use crate::ekubo::types::i129::i129;

        /// Ekubo MathLib (called via library_call on its declared class).
        #[starknet::interface]
        pub trait IMathLib<TContractState> {
            fn liquidity_delta_to_amount_delta(
                self: @TContractState,
                sqrt_ratio: u256,
                liquidity_delta: i129,
                sqrt_ratio_lower: u256,
                sqrt_ratio_upper: u256,
            ) -> Delta;
            fn max_liquidity(
                self: @TContractState,
                sqrt_ratio: u256,
                sqrt_ratio_lower: u256,
                sqrt_ratio_upper: u256,
                amount0: u128,
                amount1: u128,
            ) -> u128;
            fn tick_to_sqrt_ratio(self: @TContractState, tick: i129) -> u256;
            fn sqrt_ratio_to_tick(self: @TContractState, sqrt_ratio: u256) -> i129;
        }

        /// Mainnet MathLib class (verified on-chain: ABI exposes the functions above).
        pub fn dispatcher() -> IMathLibLibraryDispatcher {
            IMathLibLibraryDispatcher {
                class_hash: 0x037d63129281c4c42cba74218c809ffc9e6f87ca74e0bdabb757a7f236ca59c3
                    .try_into()
                    .unwrap(),
            }
        }
    }

    /// Test helpers only: pool creation + LP on Ekubo (attacker pool in the C1 fork test).
    pub mod core {
        use crate::ekubo::types::i129::i129;
        use crate::interfaces::IEkuboCore::PoolKey;

        #[starknet::interface]
        pub trait ICore<TContractState> {
            fn initialize_pool(ref self: TContractState, pool_key: PoolKey, initial_tick: i129) -> u256;
        }
    }

    pub mod positions {
        use crate::interfaces::IEkuboCore::{Bounds, PoolKey};

        #[starknet::interface]
        pub trait IPositions<TContractState> {
            fn mint_and_deposit_and_clear_both(
                ref self: TContractState, pool_key: PoolKey, bounds: Bounds, min_liquidity: u128,
            ) -> (u64, u128, u256, u256);
        }
    }
}
