// Starknet mainnet addresses used by the vault and its tests.
use starknet::ContractAddress;

fn addr(a: felt252) -> ContractAddress {
    a.try_into().unwrap()
}

// AVNU exchange (multi_route_swap)
pub fn AVNU_EX() -> ContractAddress {
    addr(0x04270219d365d6b017231b52e92b3fb5d7c8378b05e9abc97724537a80e93b0f)
}
pub fn EKUBO_CORE() -> ContractAddress {
    addr(0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b)
}
pub fn EKUBO_POSITIONS() -> ContractAddress {
    addr(0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067)
}
pub fn EKUBO_POSITIONS_NFT() -> ContractAddress {
    addr(0x07b696af58c967c1b14c9dde0ace001720635a660a8e90c565ea459345318b30)
}
pub fn XSTRK_ADDRESS() -> ContractAddress {
    addr(0x028d709c875c0ceac3dce7065bec5328186dc89fe254527084d1689910954b0a)
}
pub fn STRK_ADDRESS() -> ContractAddress {
    addr(0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d)
}
pub fn ETH_ADDRESS() -> ContractAddress {
    addr(0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7)
}
pub fn USDC_ADDRESS() -> ContractAddress {
    addr(0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8)
}
pub fn USDT_ADDRESS() -> ContractAddress {
    addr(0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8)
}
// test-only: fee collector / whale-ish addresses used in fork tests
pub fn EKUBO_FEE_COLLECTOR() -> ContractAddress {
    addr(0x053c69eDcB1a65A8687Ec7Ad8fC23fD7cc815186fE4380bb6A5bf31df52361FF)
}
pub fn EKUBO_USER_ADDRESS() -> ContractAddress {
    addr(0x000d8d6dfec4d33bfb6895de9f3852143a17c6f92fd2a21da3d6924d34870160)
}
