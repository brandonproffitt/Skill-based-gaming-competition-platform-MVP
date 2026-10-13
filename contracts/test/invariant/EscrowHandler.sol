// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChallengeEscrow} from "../../src/ChallengeEscrow.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Drives the escrow through random valid sequences of actions and tracks ghost totals.
contract EscrowHandler is Test {
    ChallengeEscrow internal escrow;
    MockUSDC internal usdc;
    address internal resolver;

    address[] internal actors;
    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostFeesCredited;
    uint256 public ghostSettledPots;
    mapping(bytes32 action => uint256 count) public calls;

    constructor(ChallengeEscrow escrow_, MockUSDC usdc_, address resolver_, address[] memory actors_) {
        escrow = escrow_;
        usdc = usdc_;
        resolver = resolver_;
        actors = actors_;
    }

    function create(uint256 actorSeed, uint96 stake, uint32 acceptDelay, uint256 inviteSeed) external {
        address creator = _actor(actorSeed);
        stake = uint96(bound(stake, escrow.minStake(), escrow.maxStake()));
        uint40 acceptBy = uint40(block.timestamp + bound(acceptDelay, 1, escrow.MAX_ACCEPT_WINDOW()));
        // One in three challenges is a direct invite to someone other than the creator.
        address invited = inviteSeed % 3 == 0 ? _actor(inviteSeed / 3) : address(0);
        if (invited == creator) invited = address(0);

        usdc.mint(creator, stake);
        vm.startPrank(creator);
        usdc.approve(address(escrow), stake);
        escrow.create(stake, acceptBy, invited, keccak256(abi.encode(actorSeed)));
        vm.stopPrank();
        ghostDeposited += stake;
        calls["create"]++;
    }

    function accept(uint256 idSeed, uint256 actorSeed) external {
        (uint256 id, ChallengeEscrow.Challenge memory c) = _pick(idSeed, ChallengeEscrow.Status.Open);
        if (id == 0 || block.timestamp > c.acceptBy) return;
        address opponent = c.opponent != address(0) ? c.opponent : _actor(actorSeed);
        if (opponent == c.creator) opponent = _actor(actorSeed % actors.length + 1);
        if (opponent == c.creator) return;

        usdc.mint(opponent, c.stake);
        vm.startPrank(opponent);
        usdc.approve(address(escrow), c.stake);
        escrow.accept(id);
        vm.stopPrank();
        ghostDeposited += c.stake;
        calls["accept"]++;
    }

    function cancel(uint256 idSeed) external {
        (uint256 id, ChallengeEscrow.Challenge memory c) = _pick(idSeed, ChallengeEscrow.Status.Open);
        if (id == 0) return;
        vm.prank(c.creator);
        escrow.cancel(id);
        calls["cancel"]++;
    }

    function resolve(uint256 idSeed, bool creatorWins) external {
        (uint256 id, ChallengeEscrow.Challenge memory c) = _pick(idSeed, ChallengeEscrow.Status.Active);
        if (id == 0 || block.timestamp > c.resolveBy) return;
        address feeRecipient = escrow.feeRecipient();
        uint256 feesBefore = escrow.credits(feeRecipient);
        vm.prank(resolver);
        escrow.resolve(id, creatorWins ? c.creator : c.opponent, bytes32(idSeed));
        ghostFeesCredited += escrow.credits(feeRecipient) - feesBefore;
        ghostSettledPots += 2 * uint256(c.stake);
        calls["resolve"]++;
    }

    function resolveDraw(uint256 idSeed) external {
        (uint256 id, ChallengeEscrow.Challenge memory c) = _pick(idSeed, ChallengeEscrow.Status.Active);
        if (id == 0 || block.timestamp > c.resolveBy) return;
        vm.prank(resolver);
        escrow.resolveDraw(id, bytes32(idSeed));
        calls["resolveDraw"]++;
    }

    function refundExpired(uint256 idSeed, uint256 callerSeed) external {
        uint256 count = escrow.nextId() - 1;
        if (count == 0) return;
        for (uint256 i; i < count; ++i) {
            uint256 id = (idSeed % count + i) % count + 1;
            ChallengeEscrow.Challenge memory c = escrow.getChallenge(id);
            bool expired = (c.status == ChallengeEscrow.Status.Open && block.timestamp > c.acceptBy)
                || (c.status == ChallengeEscrow.Status.Active && block.timestamp > c.resolveBy);
            if (expired) {
                vm.prank(_actor(callerSeed));
                escrow.refundExpired(id);
                calls["refundExpired"]++;
                return;
            }
        }
    }

    function withdraw(uint256 actorSeed) external {
        address account =
            actorSeed % (actors.length + 1) == actors.length ? escrow.feeRecipient() : _actor(actorSeed);
        uint256 owed = escrow.credits(account);
        if (owed == 0) return;
        vm.prank(account);
        escrow.withdraw();
        ghostWithdrawn += owed;
        calls["withdraw"]++;
    }

    function warp(uint32 delta) external {
        vm.warp(block.timestamp + bound(delta, 1, 10 days));
    }

    function actorsList() external view returns (address[] memory) {
        return actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Returns a challenge in `status`, scanning from a random start, or id 0 if none.
    function _pick(uint256 seed, ChallengeEscrow.Status status)
        internal
        view
        returns (uint256 id, ChallengeEscrow.Challenge memory c)
    {
        uint256 count = escrow.nextId() - 1;
        for (uint256 i; i < count; ++i) {
            uint256 candidate = (seed % count + i) % count + 1;
            c = escrow.getChallenge(candidate);
            if (c.status == status) return (candidate, c);
        }
    }
}
