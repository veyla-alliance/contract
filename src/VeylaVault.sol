// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./interfaces/IXcm.sol";
import "./interfaces/IERC20Precompile.sol";

/// @title  VeylaVault
/// @notice Automated yield optimization vault on Polkadot Hub.
///         Accepts DOT (native, via msg.value) and USDT (via pallet-assets ERC-20 precompile).
///         Routes liquidity cross-chain via Polkadot's XCM precompile for yield optimization.
/// @dev    Built for Polkadot Solidity Hackathon 2026 — Track 2: PVM Smart Contracts.
///         Deployed on Passet Hub Testnet (chain ID 420420422).
contract VeylaVault {

    // ── Sentinel for DOT (native Polkadot asset) ──────────────────────────
    // DOT is deposited via msg.value — no ERC-20 precompile exists for DOT yet on Passet Hub.
    // address(0) is used as a sentinel token identifier for DOT throughout the contract.
    address public constant DOT = address(0);

    // ── USDT via pallet-assets ERC-20 precompile ──────────────────────────
    // Asset ID 1984 (0x7C0) → precompile address formula: [assetId 8hex][24 zeros][01200000]
    address public constant USDT = USDT_PRECOMPILE;

    // ── APY cap ───────────────────────────────────────────────────────────
    // Prevents catastrophic drain: owner cannot set APY above 100% (10_000 bps).
    uint256 public constant MAX_APY_BPS = 10_000;

    // ── State ─────────────────────────────────────────────────────────────

    address public owner;
    address public pendingOwner;
    bool public paused;

    // user → token → deposited principal (in token's native decimals)
    // DOT: 10 decimals on Polkadot (but handled as native ETH-like value in PolkaVM)
    // USDT: 6 decimals
    mapping(address => mapping(address => uint256)) private _balances;

    // user → token → timestamp of last accrual snapshot
    mapping(address => mapping(address => uint256)) private _depositTimestamps;

    // user → token → yield snapshotted before a new deposit (multi-deposit accuracy)
    mapping(address => mapping(address => uint256)) private _accruedYield;

    // token → APY in basis points (e.g. 1420 = 14.20%)
    mapping(address => uint256) private _apyBps;

    // token → total deposited (TVL per asset)
    mapping(address => uint256) private _tvl;

    // ── Events ────────────────────────────────────────────────────────────

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);
    event YieldClaimed(address indexed user, address indexed token, uint256 amount);
    event Routed(address indexed token, address destination, uint256 amount);
    event ApyUpdated(address indexed token, uint256 newApyBps);
    event Paused(bool isPaused);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ── Errors ────────────────────────────────────────────────────────────

    error ZeroAmount();
    error InsufficientBalance();
    error NotOwner();
    error TransferFailed();
    error UnsupportedToken();
    error ContractPaused();
    error MsgValueMismatch();
    error ApyExceedsCap();
    error ZeroAddress();
    error NoPendingOwner();

    // ── Modifiers ─────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier notPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────

    constructor() {
        owner = msg.sender;
        // Default APY — mirrors frontend display values
        _apyBps[DOT]  = 1420; // 14.20% → routed to Hydration Omnipool
        _apyBps[USDT] =  980; // 9.80%  → routed to Stellaswap on Moonbeam
    }

    // ── Deposit ───────────────────────────────────────────────────────────

    /// @notice Deposit DOT or USDT into the Veyla vault.
    /// @param  token   address(0) for DOT — send native DOT via msg.value.
    ///                 USDT_PRECOMPILE for USDT — must approve vault first.
    /// @param  amount  ERC-20 amount for USDT (ignored for DOT, use msg.value).
    function deposit(address token, uint256 amount) external payable notPaused {
        if (token == DOT) {
            if (msg.value == 0) revert ZeroAmount();
            _accrueYield(msg.sender, DOT);
            _balances[msg.sender][DOT] += msg.value;
            _tvl[DOT] += msg.value;
            emit Deposited(msg.sender, DOT, msg.value);

        } else if (token == USDT) {
            if (amount == 0) revert ZeroAmount();
            if (msg.value != 0) revert MsgValueMismatch();
            bool ok = IERC20Precompile(USDT).transferFrom(msg.sender, address(this), amount);
            if (!ok) revert TransferFailed();
            _accrueYield(msg.sender, USDT);
            _balances[msg.sender][USDT] += amount;
            _tvl[USDT] += amount;
            emit Deposited(msg.sender, USDT, amount);

        } else {
            revert UnsupportedToken();
        }
    }

    // ── Withdraw ──────────────────────────────────────────────────────────

    /// @notice Withdraw deposited assets from the vault.
    ///         Always returns the full principal. Yield is paid from the available yield pool
    ///         (funded by XCM returns via receive() or owner via fundYieldPool()).
    ///         If the yield pool is insufficient, any unpaid yield remains in _accruedYield
    ///         and can be claimed later via claimYield() — principal is NEVER locked.
    /// @param  token   address(0) for DOT, USDT_PRECOMPILE for USDT.
    /// @param  amount  Amount of PRINCIPAL to withdraw (in token's native decimals).
    /// @dev    Security note: this contract uses a single owner key (EOA). In production,
    ///         replace with a multisig or timelock before mainnet deployment.
    function withdraw(address token, uint256 amount) external notPaused {
        if (amount == 0) revert ZeroAmount();
        if (_balances[msg.sender][token] < amount) revert InsufficientBalance();

        // Snapshot all pending yield into _accruedYield before touching balance
        _accrueYield(msg.sender, token);

        uint256 yieldDue = _accruedYield[msg.sender][token];

        // ── Cap yield at available pool so principal is ALWAYS withdrawable ──
        // Yield pool = vault balance minus all deposited principals.
        // Any yield not paid now stays in _accruedYield for future claimYield() calls.
        uint256 yieldPool;
        if (token == DOT) {
            yieldPool = address(this).balance > _tvl[DOT]
                ? address(this).balance - _tvl[DOT]
                : 0;
        } else {
            uint256 vaultBal = IERC20Precompile(USDT).balanceOf(address(this));
            yieldPool = vaultBal > _tvl[USDT]
                ? vaultBal - _tvl[USDT]
                : 0;
        }
        uint256 actualYield    = yieldDue > yieldPool ? yieldPool : yieldDue;
        uint256 remainingYield = yieldDue - actualYield;
        uint256 totalPayout    = amount + actualYield;

        // ── Checks-Effects-Interactions: update state BEFORE external call ──
        _balances[msg.sender][token]    -= amount;
        _tvl[token]                     -= amount;
        _accruedYield[msg.sender][token] = remainingYield; // preserve unclaimed yield

        if (token == DOT) {
            (bool ok,) = payable(msg.sender).call{value: totalPayout}("");
            if (!ok) revert TransferFailed();

        } else if (token == USDT) {
            bool ok = IERC20Precompile(USDT).transfer(msg.sender, totalPayout);
            if (!ok) revert TransferFailed();

        } else {
            revert UnsupportedToken();
        }

        emit Withdrawn(msg.sender, token, totalPayout);
    }

    /// @notice Claim accrued yield without withdrawing the principal.
    ///         Useful for harvesting yield while keeping the position open.
    ///         Capped at available yield pool — if pool is empty, reverts with ZeroAmount.
    /// @param  token  address(0) for DOT, USDT_PRECOMPILE for USDT.
    function claimYield(address token) external notPaused {
        if (token != DOT && token != USDT) revert UnsupportedToken();

        // Snapshot pending yield into _accruedYield
        _accrueYield(msg.sender, token);

        uint256 yieldDue = _accruedYield[msg.sender][token];
        if (yieldDue == 0) revert ZeroAmount();

        // Cap at available yield pool (same logic as withdraw)
        uint256 yieldPool;
        if (token == DOT) {
            yieldPool = address(this).balance > _tvl[DOT]
                ? address(this).balance - _tvl[DOT]
                : 0;
        } else {
            uint256 vaultBal = IERC20Precompile(USDT).balanceOf(address(this));
            yieldPool = vaultBal > _tvl[USDT]
                ? vaultBal - _tvl[USDT]
                : 0;
        }
        if (yieldPool == 0) revert ZeroAmount();

        uint256 actualYield = yieldDue > yieldPool ? yieldPool : yieldDue;

        // CEI: update state before transfer
        _accruedYield[msg.sender][token] = yieldDue - actualYield;

        if (token == DOT) {
            (bool ok,) = payable(msg.sender).call{value: actualYield}("");
            if (!ok) revert TransferFailed();
        } else {
            bool ok = IERC20Precompile(USDT).transfer(msg.sender, actualYield);
            if (!ok) revert TransferFailed();
        }

        emit YieldClaimed(msg.sender, token, actualYield);
    }

    // ── Read (matches frontend ABI exactly) ───────────────────────────────

    /// @notice Returns deposited principal for a user and token.
    function balanceOf(address user, address token) external view returns (uint256) {
        return _balances[user][token];
    }

    /// @notice Returns total yield earned by a user for a given token.
    ///         Includes both snapshotted yield and pending yield since last deposit.
    function earned(address user, address token) external view returns (uint256) {
        return _accruedYield[user][token] + _pendingYield(user, token);
    }

    /// @notice Returns current APY for a token in basis points (e.g. 1420 = 14.20%).
    function currentApy(address token) external view returns (uint256) {
        return _apyBps[token];
    }

    /// @notice Returns combined TVL across all assets in RAW token units (NOT USD).
    /// @dev    WARNING: This naively adds DOT (18 decimals in PolkaVM) + USDT (6 decimals).
    ///         The result is only meaningful as an aggregate count, NOT a USD value.
    ///         Use tvlOf(token) per-asset + a price oracle for accurate USD TVL.
    function tvl() external view returns (uint256) {
        return _tvl[DOT] + _tvl[USDT];
    }

    /// @notice Returns TVL for a specific token.
    function tvlOf(address token) external view returns (uint256) {
        return _tvl[token];
    }

    // ── Admin: XCM Routing ────────────────────────────────────────────────

    /// @notice Execute an XCM message locally via Polkadot Hub's XCM precompile.
    ///         Used to route assets within the current chain context.
    /// @param  token       Asset being routed (DOT or USDT).
    /// @param  xcmMessage  SCALE-encoded XCM message bytes.
    /// @dev    XCM precompile address: 0x00000000000000000000000000000000000a0000
    function routeAssets(
        address token,
        bytes calldata xcmMessage
    ) external onlyOwner {
        if (_tvl[token] == 0) revert ZeroAmount();

        // Estimate weight required for XCM execution (Polkadot Hub precompile call)
        IXcm.Weight memory weight = IXcm(XCM_PRECOMPILE).weighMessage(xcmMessage);

        // Execute XCM message via Polkadot Hub native precompile
        IXcm(XCM_PRECOMPILE).execute(xcmMessage, weight);

        emit Routed(token, XCM_PRECOMPILE, _tvl[token]);
    }

    /// @notice Send an XCM message to another parachain (cross-chain routing).
    ///         Used to move assets to yield-generating chains like Hydration or Moonbeam.
    /// @param  token        Asset being routed.
    /// @param  destination  SCALE-encoded XCM MultiLocation of the target parachain.
    /// @param  xcmMessage   SCALE-encoded XCM message (WithdrawAsset + BuyExecution + DepositAsset).
    function sendCrossChain(
        address token,
        bytes calldata destination,
        bytes calldata xcmMessage
    ) external onlyOwner {
        if (_tvl[token] == 0) revert ZeroAmount();

        // Send XCM message cross-chain to target parachain
        IXcm(XCM_PRECOMPILE).send(destination, xcmMessage);

        emit Routed(token, XCM_PRECOMPILE, _tvl[token]);
    }

    // ── Admin: Config ─────────────────────────────────────────────────────

    /// @notice Update APY for a token (owner only).
    /// @param  apyBps  New APY in basis points (e.g. 1420 = 14.20%).
    ///                 Capped at MAX_APY_BPS (10_000 = 100%) to prevent drain attacks.
    function setApy(address token, uint256 apyBps) external onlyOwner {
        if (apyBps > MAX_APY_BPS) revert ApyExceedsCap();
        _apyBps[token] = apyBps;
        emit ApyUpdated(token, apyBps);
    }

    /// @notice Pause or unpause all deposits and withdrawals.
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    /// @notice Step 1 — Nominate a new owner. Ownership does NOT transfer until
    ///         the nominee calls acceptOwnership(). This prevents permanent lock-out
    ///         from a typo or wrong address.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Step 2 — Pending owner accepts and finalises the transfer.
    ///         Only callable by the address nominated in transferOwnership().
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NoPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner        = pendingOwner;
        pendingOwner = address(0);
    }

    /// @notice Fund the yield pool with native DOT so withdraw() can pay yield.
    ///         In production, yield funds come automatically via XCM returns (receive()).
    ///         On testnet, owner can call this to manually seed the yield pool for demos.
    function fundYieldPool() external payable onlyOwner {
        // Simply accept the transfer — vault balance increases, enabling yield payouts.
        // No state changes needed: receive() also handles this.
    }

    // ── Internal ──────────────────────────────────────────────────────────

    /// @dev Snapshot all pending yield into _accruedYield, then reset timestamp.
    ///      Called before any balance-changing operation to maintain yield accuracy.
    function _accrueYield(address user, address token) internal {
        _accruedYield[user][token] += _pendingYield(user, token);
        _depositTimestamps[user][token] = block.timestamp;
    }

    /// @dev Calculate yield earned since the last snapshot (not yet saved to storage).
    ///      Formula: principal × APY% × elapsed / 365 days
    function _pendingYield(address user, address token) internal view returns (uint256) {
        uint256 principal = _balances[user][token];
        if (principal == 0) return 0;
        uint256 ts = _depositTimestamps[user][token];
        if (ts == 0) return 0;
        uint256 elapsed = block.timestamp - ts;
        // yield = principal * apyBps * elapsed / (365 days * 10_000)
        return (principal * _apyBps[token] * elapsed) / (365 days * 10_000);
    }

    // ── Fallback ──────────────────────────────────────────────────────────

    /// @dev Accept direct DOT transfers (e.g. from XCM callbacks).
    receive() external payable {}
}
