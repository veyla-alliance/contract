// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./interfaces/IXcm.sol";
import "./interfaces/IERC20Precompile.sol";

/// @title  VeylaVault
/// @notice Automated yield optimization vault on Polkadot Hub.
///         Accepts DOT (native, via msg.value) and USDT (via pallet-assets ERC-20 precompile).
///         Routes liquidity cross-chain via Polkadot's XCM precompile for yield optimization.
/// @dev    Built for Polkadot Solidity Hackathon 2026 — Track 2: PVM Smart Contracts.
///         Deployed on Passet Hub Testnet (chain ID 420420417).
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

    // ── XCM message size cap ──────────────────────────────────────────────
    // A valid XCM message for asset routing is never more than 1 KB.
    // Prevents bloated calldata griefing via large xcmMessage payloads.
    uint256 public constant MAX_XCM_MESSAGE_SIZE = 1024;

    // Protocol fee cap — owner cannot set fee above 5% (500 bps)
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 500;

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

    // ── Protocol Config ────────────────────────────────────────────────────
    // Protocol fee on yield — mutable by owner, capped at MAX_PROTOCOL_FEE_BPS
    uint256 public protocolFeeBps = 50;       // default 0.5%

    // Target routing frequency (informational — not enforced on-chain)
    uint256 public rebalanceInterval = 4 hours;

    // Timestamp of the last XCM routing call (either routeAssets or sendCrossChain)
    uint256 public lastRoutedAt;

    // token → destination chain name (e.g. "Hydration", "Moonbeam")
    mapping(address => string) private _tokenRoute;

    // Treasury address — receives protocol fee on yield payouts
    address public treasury;

    // Pending treasury address — must call acceptTreasury() to activate (2-step pattern)
    address public pendingTreasury;

    // XCM destination whitelist — keccak256(destinationBytes) → allowed
    // Prevents sendCrossChain from routing to arbitrary parachains
    mapping(bytes32 => bool) public trustedDestinations;

    // ── Events ────────────────────────────────────────────────────────────

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);
    event YieldClaimed(address indexed user, address indexed token, uint256 amount);
    event RoutedLocally(address indexed token, uint256 amount);
    event RoutedCrossChain(address indexed token, bytes destination, uint256 amount);
    event ApyUpdated(address indexed token, uint256 newApyBps);
    event Paused(bool isPaused);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event YieldPoolFunded(address indexed from, uint256 amount);
    event ProtocolFeeUpdated(uint256 newFeeBps);
    event RebalanceIntervalUpdated(uint256 newInterval);
    event TokenRouteUpdated(address indexed token, string route);
    event TreasuryUpdated(address indexed newTreasury);
    event TreasuryProposed(address indexed newTreasury);
    event TrustedDestinationAdded(bytes destination);
    event TrustedDestinationRemoved(bytes destination);

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
    error FeeExceedsCap();
    error InvalidInterval();
    error RouteTooLong();
    error YieldPoolEmpty();
    error UntrustedDestination();
    error XcmMessageTooLarge();
    error NotPendingTreasury();

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
        // Default route destinations — mirrors frontend display
        _tokenRoute[DOT]  = "Hydration";
        _tokenRoute[USDT] = "Moonbeam";
        treasury = msg.sender;
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
        uint256 fee         = (actualYield * protocolFeeBps) / 10_000;
        uint256 userYield   = actualYield - fee;
        uint256 totalPayout = amount + userYield;

        // ── Checks-Effects-Interactions: update state BEFORE external call ──
        _balances[msg.sender][token]    -= amount;
        _tvl[token]                     -= amount;
        _accruedYield[msg.sender][token] = remainingYield; // preserve unclaimed yield

        if (token == DOT) {
            (bool ok,) = payable(msg.sender).call{value: totalPayout}("");
            if (!ok) revert TransferFailed();
            if (fee > 0) {
                (bool feeOk,) = payable(treasury).call{value: fee}("");
                if (!feeOk) revert TransferFailed();
            }
        } else if (token == USDT) {
            bool ok = IERC20Precompile(USDT).transfer(msg.sender, totalPayout);
            if (!ok) revert TransferFailed();
            if (fee > 0) {
                bool feeOk = IERC20Precompile(USDT).transfer(treasury, fee);
                if (!feeOk) revert TransferFailed();
            }
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
        if (yieldPool == 0) revert YieldPoolEmpty();

        uint256 actualYield = yieldDue > yieldPool ? yieldPool : yieldDue;
        uint256 fee        = (actualYield * protocolFeeBps) / 10_000;
        uint256 userYield  = actualYield - fee;

        // CEI: update state before transfer
        _accruedYield[msg.sender][token] = yieldDue - actualYield;

        if (token == DOT) {
            (bool ok,) = payable(msg.sender).call{value: userYield}("");
            if (!ok) revert TransferFailed();
            if (fee > 0) {
                (bool feeOk,) = payable(treasury).call{value: fee}("");
                if (!feeOk) revert TransferFailed();
            }
        } else {
            bool ok = IERC20Precompile(USDT).transfer(msg.sender, userYield);
            if (!ok) revert TransferFailed();
            if (fee > 0) {
                bool feeOk = IERC20Precompile(USDT).transfer(treasury, fee);
                if (!feeOk) revert TransferFailed();
            }
        }

        emit YieldClaimed(msg.sender, token, userYield);
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

    /// @notice Returns the block.timestamp of the user's last deposit (or last accrual snapshot).
    ///         Returns 0 if the user has never deposited this token.
    function depositTimestampOf(address user, address token) external view returns (uint256) {
        return _depositTimestamps[user][token];
    }

    /// @notice Returns the destination chain name for a given token (e.g. "Hydration").
    function tokenRoute(address token) external view returns (string memory) {
        return _tokenRoute[token];
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
        if (xcmMessage.length > MAX_XCM_MESSAGE_SIZE) revert XcmMessageTooLarge();

        // Estimate weight required for XCM execution (Polkadot Hub precompile call)
        IXcm.Weight memory weight = IXcm(XCM_PRECOMPILE).weighMessage(xcmMessage);

        // Execute XCM message via Polkadot Hub native precompile
        IXcm(XCM_PRECOMPILE).execute(xcmMessage, weight);

        lastRoutedAt = block.timestamp;
        emit RoutedLocally(token, _tvl[token]);
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
        if (!trustedDestinations[keccak256(destination)]) revert UntrustedDestination();
        if (xcmMessage.length > MAX_XCM_MESSAGE_SIZE) revert XcmMessageTooLarge();

        // Send XCM message cross-chain to target parachain
        IXcm(XCM_PRECOMPILE).send(destination, xcmMessage);

        lastRoutedAt = block.timestamp;
        emit RoutedCrossChain(token, destination, _tvl[token]);
    }

    // ── Admin: Config ─────────────────────────────────────────────────────

    /// @notice Update APY for a token (owner only).
    /// @param  apyBps  New APY in basis points (e.g. 1420 = 14.20%).
    ///                 Capped at MAX_APY_BPS (10_000 = 100%) to prevent drain attacks.
    function setApy(address token, uint256 apyBps) external onlyOwner {
        if (token != DOT && token != USDT) revert UnsupportedToken();
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
        emit YieldPoolFunded(msg.sender, msg.value);
    }

    /// @notice Set the protocol fee on yield (owner only).
    /// @param  feeBps  New fee in basis points. Capped at MAX_PROTOCOL_FEE_BPS (500 = 5%).
    function setProtocolFee(uint256 feeBps) external onlyOwner {
        if (feeBps > MAX_PROTOCOL_FEE_BPS) revert FeeExceedsCap();
        protocolFeeBps = feeBps;
        emit ProtocolFeeUpdated(feeBps);
    }

    /// @notice Set the target rebalance interval (owner only, informational).
    /// @param  interval  Must be between 1 hour and 365 days (inclusive).
    function setRebalanceInterval(uint256 interval) external onlyOwner {
        if (interval < 1 hours || interval > 365 days) revert InvalidInterval();
        rebalanceInterval = interval;
        emit RebalanceIntervalUpdated(interval);
    }

    /// @notice Update the destination chain name for a token (owner only).
    function setTokenRoute(address token, string calldata route) external onlyOwner {
        if (token != DOT && token != USDT) revert UnsupportedToken();
        if (bytes(route).length > 64) revert RouteTooLong();
        _tokenRoute[token] = route;
        emit TokenRouteUpdated(token, route);
    }

    /// @notice Step 1 — Propose a new treasury address.
    ///         The new address must call acceptTreasury() to activate.
    ///         This prevents mis-typed addresses from silently redirecting protocol fees.
    function proposeTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        pendingTreasury = newTreasury;
        emit TreasuryProposed(newTreasury);
    }

    /// @notice Step 2 — Pending treasury accepts and activates.
    ///         Only callable by the address nominated in proposeTreasury().
    function acceptTreasury() external {
        if (msg.sender != pendingTreasury) revert NotPendingTreasury();
        treasury = pendingTreasury;
        pendingTreasury = address(0);
        emit TreasuryUpdated(treasury);
    }

    /// @notice Whitelist a cross-chain destination for sendCrossChain() (owner only).
    /// @param  destination  SCALE-encoded XCM MultiLocation bytes of the trusted parachain.
    function addTrustedDestination(bytes calldata destination) external onlyOwner {
        trustedDestinations[keccak256(destination)] = true;
        emit TrustedDestinationAdded(destination);
    }

    /// @notice Remove a cross-chain destination from the whitelist (owner only).
    function removeTrustedDestination(bytes calldata destination) external onlyOwner {
        trustedDestinations[keccak256(destination)] = false;
        emit TrustedDestinationRemoved(destination);
    }

    // ── Internal ──────────────────────────────────────────────────────────

    /// @dev Snapshot all pending yield into _accruedYield, then reset timestamp.
    ///      Called before any balance-changing operation to maintain yield accuracy.
    function _accrueYield(address user, address token) internal {
        _accruedYield[user][token] += _pendingYield(user, token);
        _depositTimestamps[user][token] = block.timestamp;
    }

    /// @dev Calculate yield earned since the last snapshot (not yet saved to storage).
    ///      Formula: principal × APY_bps × elapsed / (365 days × 10_000)
    ///      Uses integer division — for DOT (18 decimals) precision is sub-wei.
    ///      For USDT (6 decimals), amounts below ~0.001 USDT for short durations
    ///      may truncate to 0; this is acceptable given the minimum practical deposit size.
    ///      Returns 0 if principal or timestamp is zero.
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
    ///      Emits YieldPoolFunded so every inbound payment is traceable on-chain.
    receive() external payable {
        emit YieldPoolFunded(msg.sender, msg.value);
    }
}
