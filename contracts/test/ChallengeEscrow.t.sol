// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ChallengeEscrow} from "../src/ChallengeEscrow.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";

contract ChallengeEscrowTest is Test {
    ChallengeEscrow internal escrow;
    MockUSDC internal usdc;

    address internal owner = makeAddr("owner");
    address internal resolver = makeAddr("resolver");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint16 internal constant FEE_BPS = 500; // 5%
    uint32 internal constant RESOLVE_WINDOW = 7 days;
    uint96 internal constant MIN_STAKE = 1e6; // 1 USDC
    uint96 internal constant MAX_STAKE = 1_000e6; // 1000 USDC
    uint96 internal constant STAKE = 10e6;
    bytes32 internal constant RULES = keccak256("rules");
    bytes32 internal constant EVIDENCE = keccak256("evidence");

    event ChallengeCreated(
        uint256 indexed id,
        address indexed creator,
        address indexed invitedOpponent,
        uint96 stake,
        uint40 acceptBy,
        uint16 feeBps,
        uint32 resolveWindow,
        bytes32 rulesHash
    );
    event ChallengeAccepted(uint256 indexed id, address indexed opponent, uint40 resolveBy);
    event ChallengeCancelled(uint256 indexed id);
    event ChallengeSettled(
        uint256 indexed id, address indexed winner, uint256 payout, uint256 fee, bytes32 evidenceHash
    );
    event ChallengeDrawn(uint256 indexed id, bytes32 evidenceHash);
    event ChallengeExpired(uint256 indexed id);
    event Withdrawn(address indexed account, uint256 amount);

    function setUp() public {
        usdc = new MockUSDC();
        escrow = new ChallengeEscrow(
            IERC20(address(usdc)), owner, resolver, treasury, FEE_BPS, RESOLVE_WINDOW, MIN_STAKE, MAX_STAKE
        );
        address[3] memory players = [alice, bob, carol];
        for (uint256 i; i < players.length; ++i) {
            usdc.mint(players[i], 10_000e6);
            vm.prank(players[i]);
            usdc.approve(address(escrow), type(uint256).max);
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _create(address creator, address invited) internal returns (uint256 id) {
        vm.prank(creator);
        id = escrow.create(STAKE, uint40(block.timestamp + 1 days), invited, RULES);
    }

    function _createAndAccept() internal returns (uint256 id) {
        id = _create(alice, address(0));
        vm.prank(bob);
        escrow.accept(id);
    }

    function _status(uint256 id) internal view returns (ChallengeEscrow.Status) {
        return escrow.getChallenge(id).status;
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    function test_constructor_setsConfig() public view {
        assertEq(address(escrow.token()), address(usdc));
        assertEq(escrow.owner(), owner);
        assertEq(escrow.resolver(), resolver);
        assertEq(escrow.feeRecipient(), treasury);
        assertEq(escrow.feeBps(), FEE_BPS);
        assertEq(escrow.resolveWindow(), RESOLVE_WINDOW);
        assertEq(escrow.minStake(), MIN_STAKE);
        assertEq(escrow.maxStake(), MAX_STAKE);
        assertEq(escrow.nextId(), 1);
    }

    function test_constructor_revertsOnBadConfig() public {
        IERC20 t = IERC20(address(usdc));
        vm.expectRevert(ChallengeEscrow.ZeroAddress.selector);
        new ChallengeEscrow(IERC20(address(0)), owner, resolver, treasury, FEE_BPS, RESOLVE_WINDOW, 1, 2);
        vm.expectRevert(ChallengeEscrow.ZeroAddress.selector);
        new ChallengeEscrow(t, owner, address(0), treasury, FEE_BPS, RESOLVE_WINDOW, 1, 2);
        vm.expectRevert(ChallengeEscrow.ZeroAddress.selector);
        new ChallengeEscrow(t, owner, resolver, address(0), FEE_BPS, RESOLVE_WINDOW, 1, 2);
        vm.expectRevert(ChallengeEscrow.FeeTooHigh.selector);
        new ChallengeEscrow(t, owner, resolver, treasury, 1_001, RESOLVE_WINDOW, 1, 2);
        vm.expectRevert(ChallengeEscrow.InvalidResolveWindow.selector);
        new ChallengeEscrow(t, owner, resolver, treasury, FEE_BPS, 1 days - 1, 1, 2);
        vm.expectRevert(ChallengeEscrow.InvalidResolveWindow.selector);
        new ChallengeEscrow(t, owner, resolver, treasury, FEE_BPS, 30 days + 1, 1, 2);
        vm.expectRevert(ChallengeEscrow.InvalidStakeLimits.selector);
        new ChallengeEscrow(t, owner, resolver, treasury, FEE_BPS, RESOLVE_WINDOW, 0, 2);
        vm.expectRevert(ChallengeEscrow.InvalidStakeLimits.selector);
        new ChallengeEscrow(t, owner, resolver, treasury, FEE_BPS, RESOLVE_WINDOW, 3, 2);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ChallengeEscrow(t, address(0), resolver, treasury, FEE_BPS, RESOLVE_WINDOW, 1, 2);
    }

    // ------------------------------------------------------------------
    // create
    // ------------------------------------------------------------------

    function test_create_pullsStakeAndStoresChallenge() public {
        uint40 acceptBy = uint40(block.timestamp + 1 days);
        vm.expectEmit(address(escrow));
        emit ChallengeCreated(1, alice, address(0), STAKE, acceptBy, FEE_BPS, RESOLVE_WINDOW, RULES);
        vm.prank(alice);
        uint256 id = escrow.create(STAKE, acceptBy, address(0), RULES);

        assertEq(id, 1);
        assertEq(escrow.nextId(), 2);
        assertEq(usdc.balanceOf(address(escrow)), STAKE);
        ChallengeEscrow.Challenge memory c = escrow.getChallenge(id);
        assertEq(c.creator, alice);
        assertEq(c.opponent, address(0));
        assertEq(c.stake, STAKE);
        assertEq(c.acceptBy, acceptBy);
        assertEq(c.resolveBy, 0);
        assertEq(c.feeBps, FEE_BPS);
        assertEq(c.resolveWindow, RESOLVE_WINDOW);
        assertEq(uint8(c.status), uint8(ChallengeEscrow.Status.Open));
    }

    function test_create_idsIncrement() public {
        assertEq(_create(alice, address(0)), 1);
        assertEq(_create(bob, address(0)), 2);
        assertEq(_create(alice, carol), 3);
    }

    function test_create_revertsOnStakeOutOfBounds() public {
        uint40 acceptBy = uint40(block.timestamp + 1 days);
        vm.startPrank(alice);
        vm.expectRevert(ChallengeEscrow.InvalidStake.selector);
        escrow.create(MIN_STAKE - 1, acceptBy, address(0), RULES);
        vm.expectRevert(ChallengeEscrow.InvalidStake.selector);
        escrow.create(MAX_STAKE + 1, acceptBy, address(0), RULES);
        // Bounds themselves are allowed.
        escrow.create(MIN_STAKE, acceptBy, address(0), RULES);
        escrow.create(MAX_STAKE, acceptBy, address(0), RULES);
        vm.stopPrank();
    }

    function test_create_revertsOnBadAcceptBy() public {
        vm.startPrank(alice);
        vm.expectRevert(ChallengeEscrow.InvalidAcceptBy.selector);
        escrow.create(STAKE, uint40(block.timestamp), address(0), RULES);
        vm.expectRevert(ChallengeEscrow.InvalidAcceptBy.selector);
        escrow.create(STAKE, uint40(block.timestamp + 30 days + 1), address(0), RULES);
        escrow.create(STAKE, uint40(block.timestamp + 30 days), address(0), RULES);
        vm.stopPrank();
    }

    function test_create_revertsWhenInvitingSelfOrResolver() public {
        uint40 acceptBy = uint40(block.timestamp + 1 days);
        vm.startPrank(alice);
        vm.expectRevert(ChallengeEscrow.InvalidOpponent.selector);
        escrow.create(STAKE, acceptBy, alice, RULES);
        vm.expectRevert(ChallengeEscrow.InvalidOpponent.selector);
        escrow.create(STAKE, acceptBy, resolver, RULES);
        vm.stopPrank();
    }

    function test_create_revertsForResolver() public {
        usdc.mint(resolver, STAKE);
        vm.startPrank(resolver);
        usdc.approve(address(escrow), STAKE);
        vm.expectRevert(ChallengeEscrow.ResolverCannotPlay.selector);
        escrow.create(STAKE, uint40(block.timestamp + 1 days), address(0), RULES);
        vm.stopPrank();
    }

    function test_create_revertsWhenPaused() public {
        vm.prank(owner);
        escrow.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.create(STAKE, uint40(block.timestamp + 1 days), address(0), RULES);
    }

    function test_create_revertsWithoutApproval() public {
        address dave = makeAddr("dave");
        usdc.mint(dave, STAKE);
        vm.prank(dave);
        vm.expectRevert();
        escrow.create(STAKE, uint40(block.timestamp + 1 days), address(0), RULES);
    }

    function test_create_rejectsFeeOnTransferToken() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        ChallengeEscrow e = new ChallengeEscrow(
            IERC20(address(fot)), owner, resolver, treasury, FEE_BPS, RESOLVE_WINDOW, MIN_STAKE, MAX_STAKE
        );
        fot.mint(alice, STAKE);
        vm.startPrank(alice);
        fot.approve(address(e), STAKE);
        vm.expectRevert(ChallengeEscrow.UnexpectedTransferAmount.selector);
        e.create(STAKE, uint40(block.timestamp + 1 days), address(0), RULES);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // cancel
    // ------------------------------------------------------------------

    function test_cancel_creditsCreator() public {
        uint256 id = _create(alice, address(0));
        vm.expectEmit(address(escrow));
        emit ChallengeCancelled(id);
        vm.prank(alice);
        escrow.cancel(id);
        assertEq(uint8(_status(id)), uint8(ChallengeEscrow.Status.Cancelled));
        assertEq(escrow.credits(alice), STAKE);
    }

    function test_cancel_worksWhilePaused() public {
        uint256 id = _create(alice, address(0));
        vm.prank(owner);
        escrow.pause();
        vm.prank(alice);
        escrow.cancel(id);
        assertEq(escrow.credits(alice), STAKE);
    }

    function test_cancel_revertsForNonCreator() public {
        uint256 id = _create(alice, address(0));
        vm.prank(bob);
        vm.expectRevert(ChallengeEscrow.NotCreator.selector);
        escrow.cancel(id);
    }

    function test_cancel_revertsWhenNotOpen() public {
        uint256 id = _createAndAccept();
        vm.prank(alice);
        vm.expectRevert(ChallengeEscrow.InvalidStatus.selector);
        escrow.cancel(id);

        vm.prank(alice);
        vm.expectRevert(ChallengeEscrow.InvalidStatus.selector);
        escrow.cancel(999);
    }

    function test_cancel_cannotDoubleCredit() public {
        uint256 id = _create(alice, address(0));
        vm.startPrank(alice);
        escrow.cancel(id);
        vm.expectRevert(ChallengeEscrow.InvalidStatus.selector);
        escrow.cancel(id);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // accept
    // ------------------------------------------------------------------

    function test_accept_pullsMatchingStakeAndActivates() public {
        uint256 id = _create(alice, address(0));
        uint40 expectedResolveBy = uint40(block.timestamp + RESOLVE_WINDOW);
        vm.expectEmit(address(escrow));
        emit ChallengeAccepted(id, bob, expectedResolveBy);
        vm.prank(bob);
        escrow.accept(id);

        ChallengeEscrow.Challenge memory c = escrow.getChallenge(id);
        assertEq(c.opponent, bob);
        assertEq(c.resolveBy, expectedResolveBy);
        assertEq(uint8(c.status), uint8(ChallengeEscrow.Status.Active));
        assertEq(usdc.balanceOf(address(escrow)), 2 * uint256(STAKE));
    }

    function test_accept_atExactDeadline() public {
        uint256 id = _create(alice, address(0));
        vm.warp(escrow.getChallenge(id).acceptBy);
        vm.prank(bob);
        escrow.accept(id);
        assertEq(uint8(_status(id)), uint8(ChallengeEscrow.Status.Active));
    }

    function test_accept_revertsAfterDeadline() public {
        uint256 id = _create(alice, address(0));
        vm.warp(escrow.getChallenge(id).acceptBy + 1);
        vm.prank(bob);
        vm.expectRevert(ChallengeEscrow.DeadlinePassed.selector);
        escrow.accept(id);
    }

    function test_accept_revertsForOwnChallenge() public {
        uint256 id = _create(alice, address(0));
        vm.prank(alice);
        vm.expectRevert(ChallengeEscrow.InvalidOpponent.selector);
        escrow.accept(id);
    }

    function test_accept_revertsForResolver() public {
        uint256 id = _create(alice, address(0));
        usdc.mint(resolver, STAKE);
        vm.startPrank(resolver);
        usdc.approve(address(escrow), STAKE);
        vm.expectRevert(ChallengeEscrow.ResolverCannotPlay.selector);
        escrow.accept(id);
        vm.stopPrank();
    }

    function test_accept_invitedOnly() public {
        uint256 id = _create(alice, bob);
        vm.prank(carol);
        vm.expectRevert(ChallengeEscrow.NotInvited.selector);
        escrow.accept(id);

        vm.prank(bob);
        escrow.accept(id);
        assertEq(escrow.getChallenge(id).opponent, bob);
    }

    function test_accept_revertsWhenNotOpen() public {
        uint256 id = _createAndAccept();
        vm.prank(carol);
        vm.expectRevert(ChallengeEscrow.InvalidStatus.selector);
        escrow.accept(id);

        vm.prank(carol);
        vm.expectRevert(ChallengeEscrow.InvalidStatus.selector);
        escrow.accept(999);
    }

    function test_accept_revertsWhenPaused() public {
        uint256 id = _create(alice, address(0));
        vm.prank(owner);
        escrow.pause();
        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.accept(id);
    }

    function test_accept_usesSnapshottedResolveWindow() public {
        uint256 id = _create(alice, address(0));
        vm.prank(owner);
        escrow.setResolveWindow(30 days);
        vm.prank(bob);
        escrow.accept(id);
        assertEq(escrow.getChallenge(id).resolveBy, uint40(block.timestamp + RESOLVE_WINDOW));
    }

    // ------------------------------------------------------------------
    // resolve
    // ------------------------------------------------------------------

    function test_resolve_creditsWinnerAndFee() public {
        uint256 id = _createAndAccept();
        uint256 pot = 2 * uint256(STAKE);
        uint256 fee = (pot * FEE_BPS) / 10_000;

        vm.expectEmit(address(escrow));
        emit ChallengeSettled(id, bob, pot - fee, fee, EVIDENCE);
        vm.prank(resolver);
        escrow.resolve(id, bob, EVIDENCE);

        assertEq(uint8(_status(id)), uint8(ChallengeEscrow.Status.Settled));
        assertEq(escrow.credits(bob), pot - fee);
        assertEq(escrow.credits(treasury), fee);
        assertEq(escrow.credits(alice), 0);
    }

    function test_resolve_creatorCanWin() public {
        uint256 id = _createAndAccept();
        vm.prank(resolver);
        escrow.resolve(id, alice, EVIDENCE);
        assertGt(escrow.credits(alice), 0);
        assertEq(escrow.credits(bob), 0);
    }

    function test_resolve_usesSnapshottedFee() public {
        uint256 id = _createAndAccept();
        vm.prank(owner);
        escrow.setFeeBps(1_000);
        vm.prank(resolver);
        escrow.resolve(id, bob, EVIDENCE);
        assertEq(escrow.credits(treasury), (2 * uint256(STAKE) * FEE_BPS) / 10_000);
    }

    function test_resolve_zeroFee() public {
        vm.prank(owner);
        escrow.setFeeBps(0);
        uint256 id = _createAndAccept();
        vm.prank(resolver);
        escrow.resolve(id, bob, EVIDENCE);
        assertEq(escrow.credits(bob), 2 * uint256(STAKE));
        assertEq(escrow.credits(treasury), 0);
    }

    function test_resolve_revertsForNonResolver() public {
        uint256 id = _createAndAccept();
        address[3] memory callers = [owner, alice, bob];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(ChallengeEscrow.NotResolver.selector);
            escrow.resolve(id, callers[i], EVIDENCE);
        }
    }

    function test_resolve_revertsForThirdPartyWinner() public {
        uint256 id = _createAndAccept();
        vm.startPrank(resolver);
        vm.expectRevert(ChallengeEscrow.InvalidWinner.selector);
        escrow.resolve(id, carol, EVIDENCE);
        vm.expectRevert(ChallengeEscrow.InvalidWinner.selector);
        escrow.resolve(id, resolver, EVIDENCE);
        vm.expectRevert(ChallengeEscrow.InvalidWinner.selector);
        escrow.resolve(id, address(0), EVIDENCE);
        vm.stopPrank();
    }

    function test_resolve_revertsWhenNotActive() public {
        uint256 id = _create(alice, address(0));
        vm.startPrank(resolver);
        vm.expectRevert(ChallengeEscrow.InvalidStatus.selector);
        escrow.resolve(id, alice, EVIDENCE);
        vm.expectRevert(ChallengeEscrow.InvalidStatus.selector);
        escrow.resolve(999, alice, EVIDENCE);
        vm.stopPrank();
    }

    function test_resolve_cannotResolveTwice() public {
        uint256 id = _createAndAccept();
        vm.startPrank(resolver);
        escrow.resolve(id, bob, EVIDENCE);
        vm.expectRevert(ChallengeEscrow.InvalidStatus.selector);
        escrow.resolve(id, alice, EVIDENCE);
        vm.expectRevert(ChallengeEscrow.InvalidStatus.selector);
        escrow.resolveDraw(id, EVIDENCE);
        vm.stopPrank();
    }

    function test_resolve_atExactDeadline() public {
        uint256 id = _createAndAccept();
        vm.warp(escrow.getChallenge(id).resolveBy);
        vm.prank(resolver);
        escrow.resolve(id, bob, EVIDENCE);
        assertEq(uint8(_status(id)), uint8(ChallengeEscrow.Status.Settled));
    }

    function test_resolve_revertsAfterDeadline() public {
        uint256 id = _createAndAccept();
        vm.warp(escrow.getChallenge(id).resolveBy + 1);
        vm.prank(resolver);
        vm.expectRevert(ChallengeEscrow.DeadlinePassed.selector);
        escrow.resolve(id, bob, EVIDENCE);
    }

    function test_resolve_worksWhilePaused() public {
        uint256 id = _createAndAccept();
        vm.prank(owner);
        escrow.pause();
        vm.prank(resolver);
        escrow.resolve(id, bob, EVIDENCE);
        assertEq(uint8(_status(id)), uint8(ChallengeEscrow.Status.Settled));
    }

    function test_resolve_newResolverTakesOver() public {
        uint256 id = _createAndAccept();
        address newResolver = makeAddr("newResolver");
        vm.prank(owner);
        escrow.setResolver(newResolver);

        vm.prank(resolver);
        vm.expectRevert(ChallengeEscrow.NotResolver.selector);
        escrow.resolve(id, bob, EVIDENCE);

        vm.prank(newResolver);
        escrow.resolve(id, bob, EVIDENCE);
    }

    // ------------------------------------------------------------------
    // resolveDraw
    // ------------------------------------------------------------------

    function test_resolveDraw_refundsBothWithoutFee() public {
        uint256 id = _createAndAccept();
        vm.expectEmit(address(escrow));
        emit ChallengeDrawn(id, EVIDENCE);
        vm.prank(resolver);
        escrow.resolveDraw(id, EVIDENCE);

        assertEq(uint8(_status(id)), uint8(ChallengeEscrow.Status.Drawn));
        assertEq(escrow.credits(alice), STAKE);
        assertEq(escrow.credits(bob), STAKE);
        assertEq(escrow.credits(treasury), 0);
    }

    function test_resolveDraw_revertsForNonResolver() public {
        uint256 id = _createAndAccept();
        vm.prank(alice);
        vm.expectRevert(ChallengeEscrow.NotResolver.selector);
        escrow.resolveDraw(id, EVIDENCE);
    }

    function test_resolveDraw_revertsWhenNotActive() public {
        uint256 id = _create(alice, address(0));
        vm.prank(resolver);
        vm.expectRevert(ChallengeEscrow.InvalidStatus.selector);
        escrow.resolveDraw(id, EVIDENCE);
    }

    function test_resolveDraw_revertsAfterDeadline() public {
        uint256 id = _createAndAccept();
        vm.warp(escrow.getChallenge(id).resolveBy + 1);
        vm.prank(resolver);
        vm.expectRevert(ChallengeEscrow.DeadlinePassed.selector);
        escrow.resolveDraw(id, EVIDENCE);
    }

    // ------------------------------------------------------------------
    // refundExpired
    // ------------------------------------------------------------------

    function test_refundExpired_unacceptedRefundsCreator() public {
        uint256 id = _create(alice, address(0));
        vm.warp(escrow.getChallenge(id).acceptBy + 1);
        vm.expectEmit(address(escrow));
        emit ChallengeExpired(id);
        vm.prank(carol); // anyone can trigger it
        escrow.refundExpired(id);

        assertEq(uint8(_status(id)), uint8(ChallengeEscrow.Status.Expired));
        assertEq(escrow.credits(alice), STAKE);
        assertEq(escrow.credits(carol), 0);
    }

    function test_refundExpired_unacceptedRevertsBeforeDeadline() public {
        uint256 id = _create(alice, address(0));
        vm.warp(escrow.getChallenge(id).acceptBy);
        vm.expectRevert(ChallengeEscrow.NotExpired.selector);
        escrow.refundExpired(id);
    }

    function test_refundExpired_unresolvedRefundsBoth() public {
        uint256 id = _createAndAccept();
        vm.warp(escrow.getChallenge(id).resolveBy + 1);
        vm.prank(carol);
        escrow.refundExpired(id);

        assertEq(uint8(_status(id)), uint8(ChallengeEscrow.Status.Expired));
        assertEq(escrow.credits(alice), STAKE);
        assertEq(escrow.credits(bob), STAKE);
        assertEq(escrow.credits(treasury), 0);
    }

    function test_refundExpired_unresolvedRevertsBeforeDeadline() public {
        uint256 id = _createAndAccept();
        vm.warp(escrow.getChallenge(id).resolveBy);
        vm.expectRevert(ChallengeEscrow.NotExpired.selector);
        escrow.refundExpired(id);
    }

    function test_refundExpired_worksWhilePaused() public {
        uint256 id = _createAndAccept();
        vm.prank(owner);
        escrow.pause();
        vm.warp(escrow.getChallenge(id).resolveBy + 1);
        escrow.refundExpired(id);
        assertEq(escrow.credits(alice), STAKE);
    }

    function test_refundExpired_revertsForFinalStates() public {
        uint256 settled = _createAndAccept();
        vm.prank(resolver);
        escrow.resolve(settled, bob, EVIDENCE);

        uint256 cancelled = _create(alice, address(0));
        vm.prank(alice);
        escrow.cancel(cancelled);

        uint256 expired = _create(alice, address(0));
        vm.warp(block.timestamp + 30 days);
        escrow.refundExpired(expired);

        uint256[4] memory ids = [settled, cancelled, expired, 999];
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(ChallengeEscrow.InvalidStatus.selector);
            escrow.refundExpired(ids[i]);
        }
    }

    // ------------------------------------------------------------------
    // withdraw
    // ------------------------------------------------------------------

    function test_withdraw_transfersCreditsOnce() public {
        uint256 id = _createAndAccept();
        vm.prank(resolver);
        escrow.resolve(id, bob, EVIDENCE);

        uint256 owed = escrow.credits(bob);
        uint256 before = usdc.balanceOf(bob);
        vm.expectEmit(address(escrow));
        emit Withdrawn(bob, owed);
        vm.prank(bob);
        escrow.withdraw();

        assertEq(usdc.balanceOf(bob), before + owed);
        assertEq(escrow.credits(bob), 0);

        vm.prank(bob);
        vm.expectRevert(ChallengeEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
    }

    function test_withdraw_feeRecipient() public {
        uint256 id = _createAndAccept();
        vm.prank(resolver);
        escrow.resolve(id, bob, EVIDENCE);
        uint256 fee = escrow.credits(treasury);
        vm.prank(treasury);
        escrow.withdraw();
        assertEq(usdc.balanceOf(treasury), fee);
    }

    function test_withdraw_worksWhilePaused() public {
        uint256 id = _create(alice, address(0));
        vm.prank(alice);
        escrow.cancel(id);
        vm.prank(owner);
        escrow.pause();
        vm.prank(alice);
        escrow.withdraw();
        assertEq(escrow.credits(alice), 0);
    }

    function test_fullLifecycle_emptiesEscrow() public {
        uint256 id = _createAndAccept();
        vm.prank(resolver);
        escrow.resolve(id, alice, EVIDENCE);
        vm.prank(alice);
        escrow.withdraw();
        vm.prank(treasury);
        escrow.withdraw();
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    function test_admin_onlyOwner() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(err);
        escrow.setResolver(alice);
        vm.expectRevert(err);
        escrow.setFeeRecipient(alice);
        vm.expectRevert(err);
        escrow.setFeeBps(0);
        vm.expectRevert(err);
        escrow.setResolveWindow(2 days);
        vm.expectRevert(err);
        escrow.setStakeLimits(1, 2);
        vm.expectRevert(err);
        escrow.pause();
        vm.expectRevert(err);
        escrow.unpause();
        vm.stopPrank();
    }

    function test_admin_setters() public {
        vm.startPrank(owner);
        escrow.setResolver(carol);
        escrow.setFeeRecipient(carol);
        escrow.setFeeBps(1_000);
        escrow.setResolveWindow(2 days);
        escrow.setStakeLimits(5, 50);
        vm.stopPrank();

        assertEq(escrow.resolver(), carol);
        assertEq(escrow.feeRecipient(), carol);
        assertEq(escrow.feeBps(), 1_000);
        assertEq(escrow.resolveWindow(), 2 days);
        assertEq(escrow.minStake(), 5);
        assertEq(escrow.maxStake(), 50);
    }

    function test_admin_settersValidate() public {
        vm.startPrank(owner);
        vm.expectRevert(ChallengeEscrow.ZeroAddress.selector);
        escrow.setResolver(address(0));
        vm.expectRevert(ChallengeEscrow.ZeroAddress.selector);
        escrow.setFeeRecipient(address(0));
        vm.expectRevert(ChallengeEscrow.FeeTooHigh.selector);
        escrow.setFeeBps(1_001);
        vm.expectRevert(ChallengeEscrow.InvalidResolveWindow.selector);
        escrow.setResolveWindow(30 days + 1);
        vm.expectRevert(ChallengeEscrow.InvalidStakeLimits.selector);
        escrow.setStakeLimits(10, 9);
        vm.stopPrank();
    }

    function test_admin_twoStepOwnershipTransfer() public {
        vm.prank(owner);
        escrow.transferOwnership(carol);
        assertEq(escrow.owner(), owner);
        assertEq(escrow.pendingOwner(), carol);
        vm.prank(carol);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), carol);
    }

    function test_admin_unpauseRestoresCreate() public {
        vm.startPrank(owner);
        escrow.pause();
        escrow.unpause();
        vm.stopPrank();
        _create(alice, address(0));
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    /// Payout + fee always equals the pot, and the fee never exceeds the configured share.
    function testFuzz_resolve_conservesPot(uint96 stake, uint16 feeBps, bool creatorWins) public {
        feeBps = uint16(bound(feeBps, 0, escrow.MAX_FEE_BPS()));
        stake = uint96(bound(stake, 1, type(uint96).max / 2));

        vm.startPrank(owner);
        escrow.setFeeBps(feeBps);
        escrow.setStakeLimits(1, type(uint96).max);
        vm.stopPrank();
        usdc.mint(alice, stake);
        usdc.mint(bob, stake);

        vm.prank(alice);
        uint256 id = escrow.create(stake, uint40(block.timestamp + 1 days), address(0), RULES);
        vm.prank(bob);
        escrow.accept(id);

        address winner = creatorWins ? alice : bob;
        vm.prank(resolver);
        escrow.resolve(id, winner, EVIDENCE);

        uint256 pot = 2 * uint256(stake);
        uint256 payout = escrow.credits(winner);
        uint256 fee = escrow.credits(treasury);
        assertEq(payout + fee, pot);
        assertLe(fee * 10_000, pot * feeBps);
        assertEq(usdc.balanceOf(address(escrow)), pot);
    }

    /// Timeouts partition cleanly: before the deadline only the normal path works, after it only refunds.
    function testFuzz_deadlines_partition(uint32 elapsed) public {
        uint256 id = _createAndAccept();
        ChallengeEscrow.Challenge memory c = escrow.getChallenge(id);
        vm.warp(block.timestamp + elapsed);

        if (block.timestamp <= c.resolveBy) {
            vm.expectRevert(ChallengeEscrow.NotExpired.selector);
            escrow.refundExpired(id);
            vm.prank(resolver);
            escrow.resolve(id, alice, EVIDENCE);
        } else {
            vm.prank(resolver);
            vm.expectRevert(ChallengeEscrow.DeadlinePassed.selector);
            escrow.resolve(id, alice, EVIDENCE);
            escrow.refundExpired(id);
        }
    }
}
