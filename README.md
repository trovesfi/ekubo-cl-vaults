# Ekubo Concentrated Liquidity Vault

Automated concentrated liquidity management protocol for Ekubo AMM, combining dynamic position management with fee auto-compounding and STRK reward harvesting.

## How It Works
The vault lets users deposit token pairs into optimized liquidity positions on Ekubo. Using similar mechanics as ERC-4626 token issuance, it automatically reinvests earned fees back into the position and handles complex operations like reward harvesting. Governance-controlled rebalancing maintains optimal price bounds while role-based security restricts critical operations. The system tracks positions via NFT ownership and enforces strict precision checks for capital efficiency.

**Multi-Pool Architecture**: The vault supports managing multiple liquidity pools simultaneously. All pools must use the same token pair (token0/token1) but can have different price bounds. This allows for more flexible liquidity distribution across different price ranges.

## Core Operations
To define convention, total assets is the total liquidity held by the vault across all managed pools. Total supply is ERC-20 tokens (shares) minted by the vault.
Every time when earned fees are added to liquidity or STRK rewards harvested to add liquidity, it increases the total liquidity (i.e. total assets) to increase the ERC-20 (share) value.

### `deposit(amount0, amount1, receiver)` 💰
- Deposits token0 and token1 amounts into the vault
- Automatically collects fees from all pools before processing deposit
- Distributes deposits proportionally across all managed pools based on current vault positions
- Mints ERC-20 shares proportional to liquidity created
- For first deposit (total_supply == 0), uses initial ratio values to calculate shares
- **Event**: `Deposit` - emitted with sender, owner (receiver), shares minted, and amounts deposited

### `withdraw(shares, receiver)` 🏧
- Burns shares and redeems proportional liquidity across all pools
- Collects fees from each pool before withdrawal
- Withdraws tokens from Ekubo positions proportionally
- Transfers assets directly to receiver
- Updates NFT state if a position empties (sets nft_id to 0)
- Returns `MyPositions` struct with detailed position breakdown
- **Event**: `Withdraw` - emitted with sender, receiver, owner, shares burned, and amounts withdrawn

### `rebalance_pool(rebalance_params)` 🔄  
**(Relayer-only function)**  
Rebalances liquidity across all managed pools:
1. Withdraws specified liquidity amounts from each pool (if `liquidity_burn > 0`)
2. Performs token swaps to optimize asset distribution (if `swap_params.token_from_amount > 0`)
3. Updates price bounds for each pool (if `new_bounds` provided)
4. Deposits liquidity with new bounds into each pool (if `liquidity_mint > 0`)
5. Validates sufficient token balances before minting
6. Each pool can be independently configured with different bounds and liquidity amounts
7. **Unused Token Validation**: After all operations complete, checks contract token balances against the configured `max_unused_balances_on_rebalance` thresholds (set by governor). If balances exceed the configured maximums, the transaction reverts with an error showing expected max and found balance.
- **Event**: `Rebalance` - emitted with array of `RangeInstruction` actions performed
- **Events**: `EkuboPositionUpdated` - emitted for each pool during withdrawal and deposit operations

### `handle_fees(pool_index)` 💸
**(Permissionless, pausable function)**
1. Collects accumulated fees from the specified Ekubo position
2. Calculates and transfers strategy fees to fee collector (based on `fee_bps`)
3. Deposits remaining fees back into the position as liquidity
4. May leave some unused token balances in the contract (handled during rebalance)
- **Event**: `HandleFees` - emitted with token addresses, original balances, deposited fee amounts, and pool info
- **Event**: `EkuboPositionUpdated` - emitted when fees are deposited as liquidity

### `harvest(rewardsContract, claim, proof, swapInfo1, swapInfo2)` 🌾
**(Relayer-only function)**
1. Claims STRK rewards from Ekubo distributor contract using merkle proof
2. Collects strategy fees (based on `fee_bps`) and transfers to fee collector
3. Swaps remaining rewards into token0 and token1 using Avnu multi-route swaps
4. Deposits swapped tokens as liquidity (handled separately via deposit/rebalance)
- **Event**: `HarvestEvent` - emitted with reward token, reward amount, and resulting token0/token1 amounts after swaps

### Pool Management

#### `add_pool(pool)` ➕
**(Governor-only function)**
- Adds a new managed pool to the vault
- Validates that the pool uses the same token pair as existing pools
- Ensures the pool doesn't already exist (same pool_key and bounds)
- Calculates and stores sqrt values for the new bounds
- **Event**: `PoolUpdated` - emitted with pool_key, bounds, pool_index, and `is_add: true`

#### `remove_pool(pool_index)` ➖
**(Governor-only function)**
- Removes a managed pool from the vault
- Requires that the pool has zero liquidity
- Swaps the removed pool with the last pool in the array (if not already last)
- **Events**: `PoolUpdated` - emitted for pool removal and any swaps that occur

### Configuration

#### `set_settings(fee_settings)` ⚙️
**(Governor-only function)**
- Updates fee settings (fee_bps and fee_collector address)
- Validates fee_bps <= 10000 (100%)
- **Event**: `FeeSettings` - emitted with new fee settings

#### `set_max_unused_balances_on_rebalance(max_unused_balances)` ⚙️
**(Governor-only function)**
- Sets the maximum allowed unused token balances after rebalance operations
- `max_unused_balances.token0`: Maximum allowed unused token0 balance (set to `0` to disable check)
- `max_unused_balances.token1`: Maximum allowed unused token1 balance (set to `0` to disable check)
- This configuration helps enforce standards - relayer must ensure rebalance operations don't leave excessive unused tokens
- **Event**: `MaxUnusedBalances` - emitted with new configuration

## View Functions

### Share Conversion
- `convert_to_shares(amount0, amount1) -> SharesInfo`: Converts asset amounts to shares (doesn't execute deposit)
- `convert_to_assets(shares) -> MyPositions`: Converts shares to asset amounts across all pools

### Position Queries
- `get_position(pool_index) -> MyPosition`: Returns current position details for a specific pool
- `get_positions() -> MyPositions`: Returns all positions across all managed pools
- `total_liquidity_per_pool(pool_index) -> u256`: Returns total liquidity for a specific pool

### Pool Information
- `get_pool_settings(pool_index) -> ClSettings`: Returns complete settings for a pool
- `get_managed_pools() -> Array<ManagedPool>`: Returns all managed pools
- `get_managed_pools_len() -> u64`: Returns number of managed pools
- `get_managed_pool(index) -> ManagedPool`: Returns specific pool by index

### Math Utilities
- `get_amount_delta(pool_index, liquidity) -> (u256, u256)`: Calculates token amounts for given liquidity
- `get_liquidity_delta(pool_index, amount0, amount1) -> u128`: Calculates liquidity for given token amounts
- `get_fee_settings() -> FeeSettings`: Returns current fee settings
- `get_max_unused_balances_on_rebalance() -> MaxUnusedBalances`: Returns current max unused balance configuration

## Events

### `Deposit`
Emitted when a user deposits tokens into the vault.
- `sender`: Address that initiated the deposit
- `owner`: Address that receives the shares (can differ from sender)
- `shares`: Number of ERC-20 shares minted
- `amount0`: Amount of token0 deposited
- `amount1`: Amount of token1 deposited

### `Withdraw`
Emitted when a user withdraws tokens from the vault.
- `sender`: Address that initiated the withdrawal
- `receiver`: Address that receives the tokens
- `owner`: Address that owns the shares (usually same as receiver)
- `shares`: Number of ERC-20 shares burned
- `amount0`: Total amount of token0 withdrawn
- `amount1`: Total amount of token1 withdrawn

### `Rebalance`
Emitted after a rebalance operation completes.
- `actions`: Array of `RangeInstruction` containing:
  - `liquidity_mint`: Amount of liquidity to mint
  - `liquidity_burn`: Amount of liquidity to burn
  - `pool_key`: Pool identifier
  - `new_bounds`: New price bounds for the pool

### `HandleFees`
Emitted when fees are collected and reinvested for a specific pool.
- `token0_addr`: Address of token0
- `token0_origin_bal`: Original token0 balance before fee collection
- `token0_deposited`: Amount of token0 fees deposited as liquidity
- `token1_addr`: Address of token1
- `token1_origin_bal`: Original token1 balance before fee collection
- `token1_deposited`: Amount of token1 fees deposited as liquidity
- `pool_info`: Complete `ManagedPool` information

### `HarvestEvent`
Emitted when STRK rewards are harvested and swapped.
- `rewardToken`: Address of the reward token (typically STRK)
- `rewardAmount`: Total reward amount claimed (after fees)
- `token0`: Address of token0
- `token0Amount`: Amount of token0 received after swap
- `token1`: Address of token1
- `token1Amount`: Amount of token1 received after swap

### `FeeSettings`
Emitted when fee settings are updated.
- `fee_bps`: Fee basis points (0-10000, where 10000 = 100%)
- `fee_collector`: Address that receives strategy fees

### `MaxUnusedBalances`
Emitted when maximum unused balance thresholds are updated.
- `token0`: Maximum allowed unused token0 balance after rebalance (0 = disabled)
- `token1`: Maximum allowed unused token1 balance after rebalance (0 = disabled)

### `PoolUpdated`
Emitted when a pool is added or removed from the vault.
- `pool_key`: Pool identifier (token0, token1, fee tier)
- `bounds`: Price bounds (lower and upper ticks)
- `pool_index`: Index of the pool in the managed_pools array
- `is_add`: `true` if pool was added, `false` if removed

### `EkuboPositionUpdated`
Emitted whenever an Ekubo position is modified (deposit, withdraw, fee reinvestment).
- `nft_id`: NFT identifier for the Ekubo position
- `pool_key`: Pool identifier
- `bounds`: Price bounds for the position
- `amount0_delta`: Change in token0 amount (i129 with sign: false = increase, true = decrease)
- `amount1_delta`: Change in token1 amount (i129 with sign)
- `liquidity_delta`: Change in liquidity (i129 with sign)

## Access Control

| Role         | Privileges                          | Methods                   |
|--------------|-------------------------------------|--------------------------|
| **Governor** | Update settings, manage pools | `set_settings()`<br>`set_max_unused_balances_on_rebalance()`<br>`add_pool()`<br>`remove_pool()` |
| **Emergency Actor** | Pause/unpause | `pause()`<br>`unpause()` |
| **Relayer**  | Execute rebalances, harvest rewards | `rebalance_pool()`<br>`harvest()` |
| **Super admin**  | Upgrade contract | `upgrade()` |
| **Public** | Deposit, withdraw, handle fees | `deposit()`<br>`withdraw()`<br>`handle_fees()` |

## Security Features
- ReentrancyGuard protection on all state-changing functions
- Pausable functionality for emergency stops
- Role-based access control for critical operations
- Precision checks to ensure share calculations remain consistent across pools
- Validation of sufficient balances before operations
- NFT-based position tracking with automatic cleanup when positions empty
