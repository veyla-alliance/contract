# VeylaVault — Smart Contract

Solidity smart contract for the Veyla yield optimization protocol, deployed on Passet Hub Testnet.

Built for **Polkadot Solidity Hackathon 2026 — Track 2: PVM Smart Contracts**.

## Deployment

**Network:** Passet Hub Testnet (Chain ID: `420420417`)

| | Address |
|---|---|
| **VeylaVault** | [`0x741Ec097b0D3dc7544c58C1B7401cb7540D2829b`](https://blockscout-testnet.polkadot.io/address/0x741ec097b0d3dc7544c58c1b7401cb7540d2829b) |
| DOT (native sentinel) | `0x0000000000000000000000000000000000000000` |
| USDT (pallet-assets precompile) | `0x000007c000000000000000000000000001200000` |
| XCM Precompile | `0x00000000000000000000000000000000000a0000` |

Contract is **verified on Blockscout** — source code visible at the link above.

## Polkadot-Native Features

| Feature | Usage |
|---|---|
| **XCM Precompile `execute()`** | `routeAssets()` calls `weighMessage()` + `execute()` to dispatch XCM locally |
| **XCM Precompile `send()`** | `sendCrossChain()` sends assets cross-chain to Hydration / Moonbeam |
| **pallet-assets ERC-20 precompile** | USDT via asset ID 1984 precompile (`0x...01200000`) |
| **Native DOT via `msg.value`** | DOT deposited as native chain asset — no ERC-20 wrapper |

## Architecture

```
VeylaVault
│
├── deposit(token, amount) payable  — DOT via msg.value / USDT via ERC-20 transferFrom
├── withdraw(token, amount)         — returns DOT native / USDT ERC-20 to user
├── balanceOf(user, token)          — deposited principal
├── earned(user, token)             — accrued yield (snapshot + pending)
├── currentApy(token)               — APY in basis points
├── tvl() / tvlOf(token)            — total value locked
│
├── routeAssets(token, xcmMessage)      — XCM precompile execute()  ← Track 2
└── sendCrossChain(token, dest, msg)    — XCM precompile send()     ← Track 2
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

**35 tests, 0 failures** (+ 2 fuzz tests, 256 runs each):

```
[PASS] testFuzz_depositAndWithdrawDot
[PASS] testFuzz_earnedAlwaysGrowsOverTime
[PASS] test_depositDot_success / updatesTvl / emitsEvent / multipleDeposits / revertIfZero
[PASS] test_depositUsdt_success / updatesTvl / revertIfZero / revertIfMsgValue
[PASS] test_withdrawDot_success / partial / emitsEvent / revertIfInsufficientBalance
[PASS] test_withdrawUsdt_success / revertIfInsufficientBalance
[PASS] test_earned_accruesOverTime / zeroBeforeDeposit / multipleDepositsAccumulate
[PASS] test_tvl_combinedAssets / decreasesOnWithdraw
[PASS] test_routeAssets_callsXcmPrecompile / revertIfZeroTvl / revertIfNotOwner
[PASS] test_sendCrossChain_callsXcmSend
[PASS] test_setApy / setPaused / transferOwnership + revert variants
Suite result: ok. 35 passed; 0 failed
```

### Deploy

```bash
cp .env.example .env
# Fill in PRIVATE_KEY and PASSET_HUB_RPC_URL

forge script script/Deploy.s.sol \
  --rpc-url $PASSET_HUB_RPC_URL \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url https://blockscout-testnet.polkadot.io/api
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
│   ├── VeylaVault.sol              # Main vault contract (260 lines)
│   └── interfaces/
│       ├── IXcm.sol                # XCM precompile interface
│       └── IERC20Precompile.sol    # pallet-assets ERC-20 interface
├── test/
│   └── VeylaVault.t.sol            # 35 unit tests + 2 fuzz tests
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
function balanceOf(address user, address token) external view returns (uint256);
function earned(address user, address token)    external view returns (uint256);
function currentApy(address token)              external view returns (uint256);
function tvl()                                  external view returns (uint256);
function tvlOf(address token)                   external view returns (uint256);

// Owner-only (XCM routing)
function routeAssets(address token, bytes calldata xcmMessage) external;
function sendCrossChain(address token, bytes calldata destination, bytes calldata xcmMessage) external;
function setApy(address token, uint256 apyBps) external;
function setPaused(bool _paused) external;
function transferOwnership(address newOwner) external;
```
