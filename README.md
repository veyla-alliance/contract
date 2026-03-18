# VeylaVault — Smart Contract

Solidity smart contract for the Veyla yield optimization protocol, deployed on Passet Hub Testnet.

Built for **Polkadot Solidity Hackathon 2026 — Track 2: PVM Smart Contracts**.

## Deployment

**Network:** Passet Hub Testnet (Chain ID: `420420417`)

| | Address |
|---|---|
| **VeylaVault** | [`0xc66ee6f7CA593fbbccEd23d8c50417C058F1EF77`](https://blockscout-testnet.polkadot.io/address/0xc66ee6f7CA593fbbccEd23d8c50417C058F1EF77) |
| DOT (native sentinel) | `0x0000000000000000000000000000000000000000` |
| USDT (pallet-assets precompile) | `0x000007c000000000000000000000000001200000` |
| XCM Precompile | `0x00000000000000000000000000000000000a0000` |
| Deployer / Owner | `0xE5d0eabe8582e8490110d83D191F66BC18b7DCbe` |

Contract is **verified on Blockscout** — source code visible at the link above.

## Polkadot-Native Features

| Feature | Usage |
|---|---|
| **XCM Precompile `execute()`** | `routeAssets()` calls `weighMessage()` + `execute()` to dispatch XCM locally |
| **XCM Precompile `send()`** | `sendCrossChain()` sends assets cross-chain to Hydration / Moonbeam |
| **pallet-assets ERC-20 precompile** | USDT via asset ID 1984 precompile (`0x...01200000`) |
| **Native DOT via `msg.value`** | DOT deposited as native chain asset — no ERC-20 wrapper |

## Security Features

| Feature | Description |
|---|---|
| **APY cap** | `MAX_APY_BPS = 10_000` (100%) — `setApy()` reverts with `ApyExceedsCap` if exceeded |
| **2-step ownership transfer** | `transferOwnership()` sets `pendingOwner`, `acceptOwnership()` finalises — prevents lock-out |
| **Principal protection** | `withdraw()` caps yield at available pool — principal is ALWAYS returnable even if yield pool is empty. Unpaid yield stays in `_accruedYield` for future `claimYield()` calls |
| **Event traceability** | `YieldPoolFunded` emitted on every inbound DOT transfer — XCM returns fully traceable on-chain |
| **Dedicated yield event** | `claimYield()` emits `YieldClaimed` (not `Withdrawn`) — indexers can distinguish yield vs principal |
| **Split routing events** | `RoutedLocally` vs `RoutedCrossChain` — clear distinction between local and cross-chain XCM |

## Architecture

```
VeylaVault
│
├── deposit(token, amount) payable  — DOT via msg.value / USDT via ERC-20 transferFrom
├── withdraw(token, amount)         — returns principal + available yield to user
├── claimYield(token)               — harvest accrued yield, position stays open
├── balanceOf(user, token)          — deposited principal
├── earned(user, token)             — accrued yield (snapshot + pending)
├── currentApy(token)               — APY in basis points (e.g. 1420 = 14.20%)
├── tvl() / tvlOf(token)            — total value locked
│
├── routeAssets(token, xcmMessage)      — XCM precompile execute()  ← Track 2
├── sendCrossChain(token, dest, msg)    — XCM precompile send()     ← Track 2
├── fundYieldPool()                     — owner seeds yield pool (testnet)
├── setApy(token, apyBps)               — update APY (capped at 100%)
├── setPaused(bool)                     — pause/unpause vault
├── transferOwnership(newOwner)         — step 1: nominate new owner
└── acceptOwnership()                   — step 2: new owner finalises transfer
```

Yield accumulation uses a snapshot pattern for accuracy across multiple deposits:
```
yield = principal × apyBps × elapsed / (365 days × 10_000)
```

## Setup

Requires [Foundry](https://getfoundry.sh).

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup
```

### Build

```bash
forge build
```

### Test

```bash
forge test -v
```

**82 tests, 0 failures** (4 fuzz tests, 256 runs each):

```
[PASS] testFuzz_depositAndWithdrawDot          (256 runs)
[PASS] testFuzz_depositWarpAndWithdrawDot      (256 runs)
[PASS] testFuzz_earnedAlwaysGrowsOverTime      (256 runs)
[PASS] testFuzz_setApy_revertAboveCap          (256 runs)
[PASS] test_depositDot_success / updatesTvl / emitsEvent / multipleDeposits / revertIfZero
[PASS] test_depositUsdt_success / updatesTvl / revertIfZero / revertIfMsgValue
[PASS] test_withdrawDot_success / partial / emitsEvent / revertIfInsufficientBalance
[PASS] test_withdrawUsdt_success / revertIfInsufficientBalance
[PASS] test_withdraw_principalSafeWhenYieldPoolEmpty
[PASS] test_withdraw_paysYieldWhenPoolFunded
[PASS] test_earned_accruesOverTime / zeroBeforeDeposit / multipleDepositsAccumulate
[PASS] test_claimYield_emitsYieldClaimedNotWithdrawn / principalUntouched / revertIfPoolEmpty
[PASS] test_tvl_combinedAssets / decreasesOnWithdraw
[PASS] test_routeAssets_callsXcmPrecompile / revertIfZeroTvl / revertIfNotOwner
[PASS] test_sendCrossChain_callsXcmSend
[PASS] test_setApy_updatesValue / revertIfNotOwner / revertIfExceedsCap / allowsMaxCap
[PASS] test_setPaused_preventsDeposit / preventsWithdraw
[PASS] test_transferOwnership_pendingOnly / acceptCompletes / revertIfNotOwner / revertIfZeroAddress
[PASS] test_acceptOwnership_revertIfNotPending / revertIfWrongAddress
[PASS] test_fundYieldPool_emitsEvent
[PASS] test_receive_emitsYieldPoolFunded
Suite result: ok. 82 passed; 0 failed
```

### Deploy

```bash
cp .env.example .env
# Fill in PRIVATE_KEY

forge create src/VeylaVault.sol:VeylaVault \
  --rpc-url https://eth-rpc-testnet.polkadot.io \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### Verify (if not done during deploy)

```bash
forge verify-contract <ADDRESS> src/VeylaVault.sol:VeylaVault \
  --verifier blockscout \
  --verifier-url https://blockscout-testnet.polkadot.io/api \
  --chain-id 420420417
```

## Project Structure

```
contract/
├── src/
│   ├── VeylaVault.sol              # Main vault contract (~370 lines)
│   └── interfaces/
│       ├── IXcm.sol                # XCM precompile interface
│       └── IERC20Precompile.sol    # pallet-assets ERC-20 interface
├── test/
│   └── VeylaVault.t.sol            # 82 unit + fuzz tests
├── script/
│   └── Deploy.s.sol                # Foundry deploy script
├── foundry.toml                    # Foundry config (Passet Hub RPC + Blockscout verifier)
├── PRECOMPILES.md                  # Passet Hub precompile addresses + research notes
└── .env.example
```

## Contract Interface

```solidity
// User-facing
function deposit(address token, uint256 amount) external payable;
function withdraw(address token, uint256 amount) external;
function claimYield(address token) external;
function balanceOf(address user, address token) external view returns (uint256);
function earned(address user, address token)    external view returns (uint256);
function currentApy(address token)              external view returns (uint256);
function tvl()                                  external view returns (uint256);
function tvlOf(address token)                   external view returns (uint256);

// Owner-only
function routeAssets(address token, bytes calldata xcmMessage) external;
function sendCrossChain(address token, bytes calldata destination, bytes calldata xcmMessage) external;
function setApy(address token, uint256 apyBps) external;   // capped at MAX_APY_BPS (100%)
function setPaused(bool _paused) external;
function fundYieldPool() external payable;
function transferOwnership(address newOwner) external;      // step 1
function acceptOwnership() external;                        // step 2 (called by pendingOwner)
```

## Events

```solidity
event Deposited(address indexed user, address indexed token, uint256 amount);
event Withdrawn(address indexed user, address indexed token, uint256 amount);
event YieldClaimed(address indexed user, address indexed token, uint256 amount);
event RoutedLocally(address indexed token, uint256 amount);
event RoutedCrossChain(address indexed token, bytes destination, uint256 amount);
event YieldPoolFunded(address indexed from, uint256 amount);
event ApyUpdated(address indexed token, uint256 newApyBps);
event Paused(bool isPaused);
event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
```
