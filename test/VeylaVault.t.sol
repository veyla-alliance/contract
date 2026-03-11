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

        // Alice gets principal + full yield
        assertGe(alice.balance, balBefore + principal + yieldAccrued - 1); // -1 wei tolerance
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

        vm.expectEmit(true, true, false, false);
        emit VeylaVault.YieldClaimed(alice, address(0), yieldAccrued);

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
        vm.expectRevert(VeylaVault.ZeroAmount.selector);
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
        emit VeylaVault.Routed(address(0), XCM_PRECOMPILE, 5 ether);

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

        vm.expectEmit(true, false, false, false);
        emit VeylaVault.Routed(address(0), XCM_PRECOMPILE, 5 ether);

        vault.sendCrossChain(address(0), dest, xcmMsg);
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

    // ── Fuzz Tests ────────────────────────────────────────────────────────

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

    function testFuzz_earnedAlwaysGrowsOverTime(uint32 elapsed) public {
        vm.assume(elapsed > 0);
        uint256 principal = 10 ether;

        vm.prank(alice);
        vault.deposit{value: principal}(address(0), 0);

        vm.warp(block.timestamp + elapsed);
        assertGt(vault.earned(alice, address(0)), 0);
    }
}
