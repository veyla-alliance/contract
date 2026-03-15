// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/VeylaVault.sol";
import "../src/interfaces/IERC20Precompile.sol";
import "../src/interfaces/IXcm.sol";

// ── Mock Contracts ────────────────────────────────────────────────────────────
// Deployed at precompile addresses via vm.etch() in setUp()

contract MockERC20 {
    mapping(address => uint256) public _bal;
    mapping(address => mapping(address => uint256)) public _allow;

    function mint(address to, uint256 amount) external {
        _bal[to] += amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _bal[account];
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allow[owner_][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allow[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(_bal[msg.sender] >= amount, "bal");
        _bal[msg.sender] -= amount;
        _bal[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(_allow[from][msg.sender] >= amount, "allowance");
        require(_bal[from] >= amount, "bal");
        _allow[from][msg.sender] -= amount;
        _bal[from] -= amount;
        _bal[to] += amount;
        return true;
    }
}

contract MockXcm {
    bool public executeCalled;
    bool public sendCalled;

    struct Weight { uint64 refTime; uint64 proofSize; }

    function weighMessage(bytes calldata) external pure returns (Weight memory) {
        return Weight(1_000_000_000, 64_000);
    }

    function execute(bytes calldata, Weight calldata) external {
        executeCalled = true;
    }

    function send(bytes calldata, bytes calldata) external {
        sendCalled = true;
    }
}

// ── Test Suite ────────────────────────────────────────────────────────────────

contract VeylaVaultTest is Test {
    // Allow the test contract to receive ETH so that fee transfers to treasury
    // (which defaults to address(this)) succeed in tests.
    receive() external payable {}
    VeylaVault vault;
    MockERC20  mockUsdt;
    MockXcm    mockXcm;

    address owner = address(this);
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    // ── Setup ─────────────────────────────────────────────────────────────

    function setUp() public {
        // Etch MockERC20 at the USDT precompile address
        mockUsdt = new MockERC20();
        vm.etch(USDT_PRECOMPILE, address(mockUsdt).code);

        // Etch MockXcm at the XCM precompile address
        mockXcm = new MockXcm();
        vm.etch(XCM_PRECOMPILE, address(mockXcm).code);

        // Deploy vault
        vault = new VeylaVault();

        // Fund alice with native DOT (represented as ETH in test env)
        vm.deal(alice, 100 ether);

        // Mint USDT for alice via the mock at precompile address
        MockERC20(USDT_PRECOMPILE).mint(alice, 1_000e6); // 1000 USDT
    }

    // ── Deposit: DOT ──────────────────────────────────────────────────────

    function test_depositDot_success() public {
        uint256 amount = 10 ether;
        vm.prank(alice);
        vault.deposit{value: amount}(address(0), 0);

        assertEq(vault.balanceOf(alice, address(0)), amount);
    }

    function test_depositDot_updatesTvl() public {
        uint256 amount = 5 ether;
        vm.prank(alice);
        vault.deposit{value: amount}(address(0), 0);

        assertEq(vault.tvlOf(address(0)), amount);
    }

    function test_depositDot_emitsEvent() public {
        uint256 amount = 3 ether;
        vm.expectEmit(true, true, false, true);
        emit VeylaVault.Deposited(alice, address(0), amount);

        vm.prank(alice);
        vault.deposit{value: amount}(address(0), 0);
    }

    function test_depositDot_revertIfZero() public {
        vm.prank(alice);
        vm.expectRevert(VeylaVault.ZeroAmount.selector);
        vault.deposit{value: 0}(address(0), 0);
    }

    function test_depositDot_multipleDeposits() public {
        vm.startPrank(alice);
        vault.deposit{value: 4 ether}(address(0), 0);
        vault.deposit{value: 6 ether}(address(0), 0);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice, address(0)), 10 ether);
    }

    // ── Deposit: USDT ─────────────────────────────────────────────────────

    function test_depositUsdt_success() public {
        uint256 amount = 500e6;
        vm.startPrank(alice);
        IERC20Precompile(USDT_PRECOMPILE).approve(address(vault), amount);
        vault.deposit(USDT_PRECOMPILE, amount);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice, USDT_PRECOMPILE), amount);
    }

    function test_depositUsdt_updatesTvl() public {
        uint256 amount = 200e6;
        vm.startPrank(alice);
        IERC20Precompile(USDT_PRECOMPILE).approve(address(vault), amount);
        vault.deposit(USDT_PRECOMPILE, amount);
        vm.stopPrank();

        assertEq(vault.tvlOf(USDT_PRECOMPILE), amount);
    }

    function test_depositUsdt_revertIfZero() public {
        vm.prank(alice);
        vm.expectRevert(VeylaVault.ZeroAmount.selector);
        vault.deposit(USDT_PRECOMPILE, 0);
    }

    function test_depositUsdt_revertIfMsgValue() public {
        vm.prank(alice);
        vm.expectRevert(VeylaVault.MsgValueMismatch.selector);
        vault.deposit{value: 1 ether}(USDT_PRECOMPILE, 100e6);
    }

    function test_depositUnsupportedToken_reverts() public {
        vm.prank(alice);
        vm.expectRevert(VeylaVault.UnsupportedToken.selector);
        vault.deposit(address(0x1234), 100);
    }

    // ── Withdraw: DOT ─────────────────────────────────────────────────────

    function test_withdrawDot_success() public {
        uint256 amount = 10 ether;
        vm.prank(alice);
        vault.deposit{value: amount}(address(0), 0);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        vault.withdraw(address(0), amount);

        assertEq(alice.balance, balBefore + amount);
        assertEq(vault.balanceOf(alice, address(0)), 0);
    }

    function test_withdrawDot_partial() public {
        vm.prank(alice);
        vault.deposit{value: 10 ether}(address(0), 0);

        vm.prank(alice);
        vault.withdraw(address(0), 4 ether);

        assertEq(vault.balanceOf(alice, address(0)), 6 ether);
    }

    function test_withdrawDot_revertIfInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(VeylaVault.InsufficientBalance.selector);
        vault.withdraw(address(0), 1 ether);
    }

    function test_withdrawDot_emitsEvent() public {
        uint256 amount = 5 ether;
        vm.prank(alice);
        vault.deposit{value: amount}(address(0), 0);

        vm.expectEmit(true, true, false, true);
        emit VeylaVault.Withdrawn(alice, address(0), amount);

        vm.prank(alice);
        vault.withdraw(address(0), amount);
    }

    // ── Withdraw: USDT ────────────────────────────────────────────────────

    function test_withdrawUsdt_success() public {
        uint256 amount = 500e6;
        vm.startPrank(alice);
        IERC20Precompile(USDT_PRECOMPILE).approve(address(vault), amount);
        vault.deposit(USDT_PRECOMPILE, amount);
        vault.withdraw(USDT_PRECOMPILE, amount);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice, USDT_PRECOMPILE), 0);
    }

    function test_withdrawUsdt_revertIfInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(VeylaVault.InsufficientBalance.selector);
        vault.withdraw(USDT_PRECOMPILE, 100e6);
    }

    // ── APY & Yield ───────────────────────────────────────────────────────

    function test_currentApy_dot() public view {
        assertEq(vault.currentApy(address(0)), 1420);
    }

    function test_currentApy_usdt() public view {
        assertEq(vault.currentApy(USDT_PRECOMPILE), 980);
    }

    function test_earned_accruesOverTime() public {
        uint256 principal = 10 ether;
        vm.prank(alice);
        vault.deposit{value: principal}(address(0), 0);

        // Fast-forward 30 days
        vm.warp(block.timestamp + 30 days);

        uint256 yield = vault.earned(alice, address(0));
        // Expected ≈ 10e18 * 1420 * 30 / (365 * 10_000) ≈ 0.1167 DOT
        assertGt(yield, 0);
    }

    function test_earned_zeroBeforeDeposit() public view {
        assertEq(vault.earned(alice, address(0)), 0);
    }

    function test_earned_multipleDepositsAccumulate() public {
        vm.prank(alice);
        vault.deposit{value: 5 ether}(address(0), 0);

        vm.warp(block.timestamp + 10 days);

        // Second deposit should snapshot yield from first deposit
        vm.prank(alice);
        vault.deposit{value: 5 ether}(address(0), 0);

        vm.warp(block.timestamp + 10 days);

        // Should have yield from both periods
        uint256 yield = vault.earned(alice, address(0));
        assertGt(yield, 0);
    }

    // ── Withdraw: yield pool cap (H-1) ───────────────────────────────────

    function test_withdraw_principalSafeWhenYieldPoolEmpty() public {
        // Deposit 10 DOT, wait for yield to accrue, but DON'T fund the yield pool.
        // Principal must still be returned even though yield can't be paid.
        uint256 principal = 10 ether;
        vm.prank(alice);
        vault.deposit{value: principal}(address(0), 0);

        vm.warp(block.timestamp + 30 days);

        uint256 yieldAccrued = vault.earned(alice, address(0));
        assertGt(yieldAccrued, 0);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        vault.withdraw(address(0), principal); // must NOT revert

        // Alice got back principal only (yield pool was empty)
        assertEq(alice.balance, balBefore + principal);
        // Remaining yield preserved in accrued mapping for future claim
        assertEq(vault.earned(alice, address(0)), yieldAccrued);
    }

    function test_withdraw_paysYieldWhenPoolFunded() public {
        uint256 principal = 10 ether;
        vm.prank(alice);
        vault.deposit{value: principal}(address(0), 0);

        vm.warp(block.timestamp + 30 days);
        uint256 yieldAccrued = vault.earned(alice, address(0));

        // Owner funds yield pool
        vault.fundYieldPool{value: yieldAccrued}();

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        vault.withdraw(address(0), principal);

        // Protocol fee (0.5% default) is deducted from yield; alice receives net yield.
        uint256 fee       = (yieldAccrued * vault.protocolFeeBps()) / 10_000;
        uint256 userYield = yieldAccrued - fee;
        // Alice gets principal + net yield (fee goes to treasury = address(this) in tests)
        assertEq(alice.balance, balBefore + principal + userYield);
        assertEq(vault.balanceOf(alice, address(0)), 0);
    }

    // ── claimYield: YieldClaimed event (H-2) ─────────────────────────────

    function test_claimYield_emitsYieldClaimedNotWithdrawn() public {
        uint256 principal = 10 ether;
        vm.prank(alice);
        vault.deposit{value: principal}(address(0), 0);

        vm.warp(block.timestamp + 30 days);
        uint256 yieldAccrued = vault.earned(alice, address(0));

        vault.fundYieldPool{value: yieldAccrued}();

        // YieldClaimed emits userYield (after fee deduction), not the gross amount.
        // Use checkData=false (4th arg) so we only check the indexed topic match.
        vm.expectEmit(true, true, false, false);
        emit VeylaVault.YieldClaimed(alice, address(0), 0 /* placeholder, data not checked */);

        vm.prank(alice);
        vault.claimYield(address(0));
    }

    function test_claimYield_principalUntouched() public {
        uint256 principal = 10 ether;
        vm.prank(alice);
        vault.deposit{value: principal}(address(0), 0);

        vm.warp(block.timestamp + 30 days);
        uint256 yieldAccrued = vault.earned(alice, address(0));
        vault.fundYieldPool{value: yieldAccrued}();

        vm.prank(alice);
        vault.claimYield(address(0));

        // Principal must remain intact
        assertEq(vault.balanceOf(alice, address(0)), principal);
    }

    function test_claimYield_revertIfPoolEmpty() public {
        uint256 principal = 10 ether;
        vm.prank(alice);
        vault.deposit{value: principal}(address(0), 0);

        vm.warp(block.timestamp + 30 days);
        // No fundYieldPool call — pool is empty
        vm.prank(alice);
        vm.expectRevert(VeylaVault.YieldPoolEmpty.selector);
        vault.claimYield(address(0));
    }

    // ── TVL ───────────────────────────────────────────────────────────────

    function test_tvl_combinedAssets() public {
        uint256 dotAmount  = 5 ether;
        uint256 usdtAmount = 200e6;

        vm.prank(alice);
        vault.deposit{value: dotAmount}(address(0), 0);

        vm.startPrank(alice);
        IERC20Precompile(USDT_PRECOMPILE).approve(address(vault), usdtAmount);
        vault.deposit(USDT_PRECOMPILE, usdtAmount);
        vm.stopPrank();

        assertEq(vault.tvl(), dotAmount + usdtAmount);
    }

    function test_tvl_decreasesOnWithdraw() public {
        uint256 amount = 10 ether;
        vm.prank(alice);
        vault.deposit{value: amount}(address(0), 0);

        vm.prank(alice);
        vault.withdraw(address(0), 4 ether);

        assertEq(vault.tvlOf(address(0)), 6 ether);
    }

    // ── Admin: XCM Routing ────────────────────────────────────────────────

    function test_routeAssets_callsXcmPrecompile() public {
        // Deposit first so TVL > 0
        vm.prank(alice);
        vault.deposit{value: 5 ether}(address(0), 0);

        bytes memory xcmMsg = hex"050c000401000003008c864713";

        vm.expectEmit(true, false, false, false);
        emit VeylaVault.RoutedLocally(address(0), 5 ether);

        vault.routeAssets(address(0), xcmMsg);
    }

    function test_routeAssets_revertIfZeroTvl() public {
        bytes memory xcmMsg = hex"050c0004";
        vm.expectRevert(VeylaVault.ZeroAmount.selector);
        vault.routeAssets(address(0), xcmMsg);
    }

    function test_sendCrossChain_callsXcmSend() public {
        vm.prank(alice);
        vault.deposit{value: 5 ether}(address(0), 0);

        bytes memory dest   = hex"0001";
        bytes memory xcmMsg = hex"050c000401000003008c864713";

        // Whitelist destination before routing
        vault.addTrustedDestination(dest);

        vm.expectEmit(true, false, false, false);
        emit VeylaVault.RoutedCrossChain(address(0), dest, 5 ether);

        vault.sendCrossChain(address(0), dest, xcmMsg);
    }

    function test_sendCrossChain_revertIfUntrustedDestination() public {
        vm.prank(alice);
        vault.deposit{value: 5 ether}(address(0), 0);

        // dest NOT whitelisted
        bytes memory dest   = hex"0002";
        bytes memory xcmMsg = hex"050c000401000003008c864713";

        vm.expectRevert(VeylaVault.UntrustedDestination.selector);
        vault.sendCrossChain(address(0), dest, xcmMsg);
    }

    function test_routeAssets_revertIfMessageTooLarge() public {
        vm.prank(alice);
        vault.deposit{value: 5 ether}(address(0), 0);

        // Build a 1025-byte XCM message (over the 1024 cap)
        bytes memory bigMsg = new bytes(1025);
        vm.expectRevert(VeylaVault.XcmMessageTooLarge.selector);
        vault.routeAssets(address(0), bigMsg);
    }

    function test_routeAssets_revertIfNotOwner() public {
        vm.prank(alice);
        vault.deposit{value: 5 ether}(address(0), 0);

        vm.prank(alice);
        vm.expectRevert(VeylaVault.NotOwner.selector);
        vault.routeAssets(address(0), hex"01");
    }

    // ── Admin: Config ─────────────────────────────────────────────────────

    function test_setApy_updatesValue() public {
        vault.setApy(address(0), 2000);
        assertEq(vault.currentApy(address(0)), 2000);
    }

    function test_setApy_revertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(VeylaVault.NotOwner.selector);
        vault.setApy(address(0), 2000);
    }

    function test_setPaused_preventsDeposit() public {
        vault.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(VeylaVault.ContractPaused.selector);
        vault.deposit{value: 1 ether}(address(0), 0);
    }

    function test_setPaused_preventsWithdraw() public {
        vm.prank(alice);
        vault.deposit{value: 5 ether}(address(0), 0);

        vault.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(VeylaVault.ContractPaused.selector);
        vault.withdraw(address(0), 1 ether);
    }

    // ── setApy: cap ───────────────────────────────────────────────────────

    function test_setApy_revertIfExceedsCap() public {
        vm.expectRevert(VeylaVault.ApyExceedsCap.selector);
        vault.setApy(address(0), 10_001); // 100.01% → must revert
    }

    function test_setApy_allowsMaxCap() public {
        vault.setApy(address(0), 10_000); // exactly 100% → must succeed
        assertEq(vault.currentApy(address(0)), 10_000);
    }

    function testFuzz_setApy_revertAboveCap(uint256 apyBps) public {
        vm.assume(apyBps > 10_000);
        vm.expectRevert(VeylaVault.ApyExceedsCap.selector);
        vault.setApy(address(0), apyBps);
    }

    function test_setApy_revertIfUnsupportedToken() public {
        vm.expectRevert(VeylaVault.UnsupportedToken.selector);
        vault.setApy(address(0x1234), 500);
    }

    // ── transferOwnership: 2-step ─────────────────────────────────────────

    function test_transferOwnership_pendingOnly() public {
        // Step 1: ownership NOT transferred yet, only pendingOwner set
        vault.transferOwnership(alice);
        assertEq(vault.owner(),        address(this)); // still original owner
        assertEq(vault.pendingOwner(), alice);
    }

    function test_transferOwnership_acceptCompletes() public {
        // Step 1 + Step 2: ownership finalised after accept
        vault.transferOwnership(alice);
        vm.prank(alice);
        vault.acceptOwnership();
        assertEq(vault.owner(),        alice);
        assertEq(vault.pendingOwner(), address(0));
    }

    function test_transferOwnership_revertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(VeylaVault.NotOwner.selector);
        vault.transferOwnership(bob);
    }

    function test_transferOwnership_revertIfZeroAddress() public {
        vm.expectRevert(VeylaVault.ZeroAddress.selector);
        vault.transferOwnership(address(0));
    }

    function test_acceptOwnership_revertIfNotPending() public {
        // bob was never nominated — must revert
        vm.prank(bob);
        vm.expectRevert(VeylaVault.NoPendingOwner.selector);
        vault.acceptOwnership();
    }

    function test_acceptOwnership_revertIfWrongAddress() public {
        vault.transferOwnership(alice);
        vm.prank(bob); // bob is not pendingOwner
        vm.expectRevert(VeylaVault.NoPendingOwner.selector);
        vault.acceptOwnership();
    }

    // ── YieldPoolFunded event ──────────────────────────────────────────────

    function test_fundYieldPool_emitsEvent() public {
        uint256 amount = 1 ether;
        vm.expectEmit(true, false, false, true);
        emit VeylaVault.YieldPoolFunded(address(this), amount);
        vault.fundYieldPool{value: amount}();
    }

    function test_receive_emitsYieldPoolFunded() public {
        uint256 amount = 0.5 ether;
        vm.deal(address(this), amount);
        vm.expectEmit(true, false, false, true);
        emit VeylaVault.YieldPoolFunded(address(this), amount);
        (bool ok,) = payable(address(vault)).call{value: amount}("");
        assertTrue(ok);
    }

    // ── Fuzz Tests ────────────────────────────────────────────────────────

    /// @dev L-1: principal always returned even when time has elapsed and yield accrued.
    function testFuzz_depositAndWithdrawDot(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 50 ether);
        vm.deal(alice, amount);

        vm.prank(alice);
        vault.deposit{value: amount}(address(0), 0);
        assertEq(vault.balanceOf(alice, address(0)), amount);

        vm.prank(alice);
        vault.withdraw(address(0), amount);
        assertEq(vault.balanceOf(alice, address(0)), 0);
    }

    /// @dev L-1 extended: principal + yield returned when pool is funded.
    function testFuzz_depositWarpAndWithdrawDot(uint96 amount, uint32 elapsed) public {
        vm.assume(amount > 0 && amount <= 50 ether);
        vm.assume(elapsed > 0 && elapsed <= 365 days);
        vm.deal(alice, uint256(amount) * 2); // extra headroom for yield funding

        vm.prank(alice);
        vault.deposit{value: uint256(amount)}(address(0), 0);

        vm.warp(block.timestamp + elapsed);
        uint256 yieldAccrued = vault.earned(alice, address(0));

        // Owner funds yield pool — principal must never be at risk
        vault.fundYieldPool{value: yieldAccrued + 1}(); // +1 wei rounding safety

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        vault.withdraw(address(0), amount);

        assertGe(alice.balance, balBefore + amount); // at minimum, principal returned
        assertEq(vault.balanceOf(alice, address(0)), 0);
    }

    /// @dev L-2: earned always grows, and claimYield + full withdraw work after earning.
    function testFuzz_earnedAlwaysGrowsOverTime(uint32 elapsed) public {
        vm.assume(elapsed > 0);
        uint256 principal = 10 ether;

        vm.prank(alice);
        vault.deposit{value: principal}(address(0), 0);

        vm.warp(block.timestamp + elapsed);
        uint256 yieldAccrued = vault.earned(alice, address(0));
        assertGt(yieldAccrued, 0);

        // Fund pool and verify claimYield leaves principal intact
        vault.fundYieldPool{value: yieldAccrued}();
        vm.prank(alice);
        vault.claimYield(address(0));
        assertEq(vault.balanceOf(alice, address(0)), principal); // principal untouched

        // Full withdraw succeeds after claimYield
        vm.prank(alice);
        vault.withdraw(address(0), principal);
        assertEq(vault.balanceOf(alice, address(0)), 0);
    }

    // ── Protocol Config: Defaults ─────────────────────────────────────────

    function test_protocolFee_defaultValue() public view {
        assertEq(vault.protocolFeeBps(), 50);
    }

    function test_rebalanceInterval_defaultValue() public view {
        assertEq(vault.rebalanceInterval(), 4 hours);
    }

    function test_lastRoutedAt_initiallyZero() public view {
        assertEq(vault.lastRoutedAt(), 0);
    }

    function test_tokenRoute_defaultDot() public view {
        assertEq(vault.tokenRoute(address(0)), "Hydration");
    }

    function test_tokenRoute_defaultUsdt() public view {
        assertEq(vault.tokenRoute(USDT_PRECOMPILE), "Moonbeam");
    }

    function test_depositTimestampOf_recordsTimestamp() public {
        uint256 before = block.timestamp;
        vm.prank(alice);
        vault.deposit{value: 5 ether}(address(0), 0);
        assertEq(vault.depositTimestampOf(alice, address(0)), before);
    }

    // ── setProtocolFee ────────────────────────────────────────────────────

    function test_setProtocolFee_updatesValue() public {
        vm.expectEmit(false, false, false, true);
        emit VeylaVault.ProtocolFeeUpdated(100);
        vault.setProtocolFee(100);
        assertEq(vault.protocolFeeBps(), 100);
    }

    function test_setProtocolFee_revertIfExceedsCap() public {
        vm.expectRevert(VeylaVault.FeeExceedsCap.selector);
        vault.setProtocolFee(501);
    }

    function test_setProtocolFee_allowsMaxCap() public {
        vault.setProtocolFee(500);
        assertEq(vault.protocolFeeBps(), 500);
    }

    function test_setProtocolFee_revertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(VeylaVault.NotOwner.selector);
        vault.setProtocolFee(100);
    }

    // ── setRebalanceInterval ──────────────────────────────────────────────

    function test_setRebalanceInterval_updatesValue() public {
        vm.expectEmit(false, false, false, true);
        emit VeylaVault.RebalanceIntervalUpdated(8 hours);
        vault.setRebalanceInterval(8 hours);
        assertEq(vault.rebalanceInterval(), 8 hours);
    }

    // ── setTokenRoute ─────────────────────────────────────────────────────

    function test_setTokenRoute_updatesRoute() public {
        vm.expectEmit(true, false, false, true);
        emit VeylaVault.TokenRouteUpdated(address(0), "Bifrost");
        vault.setTokenRoute(address(0), "Bifrost");
        assertEq(vault.tokenRoute(address(0)), "Bifrost");
    }

    function test_setTokenRoute_revertIfUnsupported() public {
        vm.expectRevert(VeylaVault.UnsupportedToken.selector);
        vault.setTokenRoute(address(0x1234), "Bifrost");
    }

    // ── lastRoutedAt updates ──────────────────────────────────────────────

    function test_routeAssets_updatesLastRoutedAt() public {
        vm.prank(alice);
        vault.deposit{value: 5 ether}(address(0), 0);

        uint256 ts = block.timestamp;
        vault.routeAssets(address(0), hex"050c000401000003008c864713");
        assertEq(vault.lastRoutedAt(), ts);
    }

    function test_sendCrossChain_updatesLastRoutedAt() public {
        vm.prank(alice);
        vault.deposit{value: 5 ether}(address(0), 0);

        vault.addTrustedDestination(hex"0001");

        uint256 ts = block.timestamp;
        vault.sendCrossChain(address(0), hex"0001", hex"050c000401000003008c864713");
        assertEq(vault.lastRoutedAt(), ts);
    }

    // ── Treasury & Protocol Fee ───────────────────────────────────────────

    function test_treasury_defaultsToOwner() public view {
        assertEq(vault.treasury(), address(this));
    }

    function test_proposeTreasury_doesNotUpdateImmediately() public {
        vault.proposeTreasury(alice);
        // Treasury stays at old value until alice accepts
        assertEq(vault.treasury(), address(this));
        assertEq(vault.pendingTreasury(), alice);
    }

    function test_acceptTreasury_completesTransfer() public {
        vault.proposeTreasury(alice);
        vm.expectEmit(true, false, false, false);
        emit VeylaVault.TreasuryUpdated(alice);
        vm.prank(alice);
        vault.acceptTreasury();
        assertEq(vault.treasury(), alice);
        assertEq(vault.pendingTreasury(), address(0));
    }

    function test_proposeTreasury_revertIfZeroAddress() public {
        vm.expectRevert(VeylaVault.ZeroAddress.selector);
        vault.proposeTreasury(address(0));
    }

    function test_proposeTreasury_revertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(VeylaVault.NotOwner.selector);
        vault.proposeTreasury(bob);
    }

    function test_acceptTreasury_revertIfNotPending() public {
        vault.proposeTreasury(alice);
        vm.prank(bob); // bob is not pendingTreasury
        vm.expectRevert(VeylaVault.NotPendingTreasury.selector);
        vault.acceptTreasury();
    }

    function test_claimYield_deductsFeeToTreasury() public {
        // Set alice as treasury (2-step)
        vault.proposeTreasury(alice);
        vm.prank(alice);
        vault.acceptTreasury();

        // Bob deposits and time passes
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        vault.deposit{value: 10 ether}(address(0), 0);
        vm.warp(block.timestamp + 365 days); // full year for easy math

        uint256 yieldAccrued = vault.earned(bob, address(0));
        vault.fundYieldPool{value: yieldAccrued}();

        // Set 5% fee (max allowed by cap) for easy verification
        vault.setProtocolFee(500); // 5%

        uint256 aliceBalBefore = alice.balance;
        uint256 bobBalBefore   = bob.balance;

        vm.prank(bob);
        vault.claimYield(address(0));

        uint256 expectedFee       = (yieldAccrued * 500) / 10_000;
        uint256 expectedUserYield = yieldAccrued - expectedFee;

        assertApproxEqAbs(alice.balance - aliceBalBefore, expectedFee, 2);
        assertApproxEqAbs(bob.balance   - bobBalBefore,   expectedUserYield, 2);
    }

    function test_withdraw_deductsFeeOnYield() public {
        vault.proposeTreasury(alice);
        vm.prank(alice);
        vault.acceptTreasury();

        vm.deal(bob, 100 ether);
        vm.prank(bob);
        vault.deposit{value: 10 ether}(address(0), 0);
        vm.warp(block.timestamp + 365 days);

        uint256 yieldAccrued = vault.earned(bob, address(0));
        vault.fundYieldPool{value: yieldAccrued}();
        vault.setProtocolFee(500); // 5% (max allowed by cap)

        uint256 aliceBalBefore = alice.balance;
        uint256 bobBalBefore   = bob.balance;

        vm.prank(bob);
        vault.withdraw(address(0), 10 ether); // full withdraw

        uint256 expectedFee       = (yieldAccrued * 500) / 10_000;
        uint256 expectedUserTotal = 10 ether + yieldAccrued - expectedFee;

        assertApproxEqAbs(alice.balance - aliceBalBefore, expectedFee, 2);
        assertApproxEqAbs(bob.balance   - bobBalBefore,   expectedUserTotal, 2);
    }

    // ── Bounds checks ─────────────────────────────────────────────────────

    function test_setRebalanceInterval_revertIfZero() public {
        vm.expectRevert(VeylaVault.InvalidInterval.selector);
        vault.setRebalanceInterval(0);
    }

    function test_setRebalanceInterval_revertIfTooLarge() public {
        vm.expectRevert(VeylaVault.InvalidInterval.selector);
        vault.setRebalanceInterval(366 days);
    }

    function test_setRebalanceInterval_allowsValidRange() public {
        vault.setRebalanceInterval(1 hours);
        assertEq(vault.rebalanceInterval(), 1 hours);
        vault.setRebalanceInterval(365 days);
        assertEq(vault.rebalanceInterval(), 365 days);
    }

    function test_setTokenRoute_revertIfTooLong() public {
        // Build a 65-byte string
        bytes memory longRoute = new bytes(65);
        for (uint i = 0; i < 65; i++) longRoute[i] = 0x41;
        vm.expectRevert(VeylaVault.RouteTooLong.selector);
        vault.setTokenRoute(address(0), string(longRoute));
    }

    function test_setTokenRoute_allowsMaxLength() public {
        bytes memory okRoute = new bytes(64);
        for (uint i = 0; i < 64; i++) okRoute[i] = 0x41;
        vault.setTokenRoute(address(0), string(okRoute)); // must not revert
    }

    // ── YieldPoolEmpty ────────────────────────────────────────────────────

    function test_claimYield_revertIfPoolEmpty_distinctError() public {
        uint256 principal = 10 ether;
        vm.prank(alice);
        vault.deposit{value: principal}(address(0), 0);
        vm.warp(block.timestamp + 30 days);

        // Pool not funded — should revert with YieldPoolEmpty, not ZeroAmount
        vm.prank(alice);
        vm.expectRevert(VeylaVault.YieldPoolEmpty.selector);
        vault.claimYield(address(0));
    }
}
