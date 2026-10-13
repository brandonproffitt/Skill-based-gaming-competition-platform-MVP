// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ChallengeEscrow} from "../../src/ChallengeEscrow.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {EscrowHandler} from "./EscrowHandler.sol";

contract ChallengeEscrowInvariantTest is Test {
    ChallengeEscrow internal escrow;
    MockUSDC internal usdc;
    EscrowHandler internal handler;
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        usdc = new MockUSDC();
        address resolver = makeAddr("resolver");
        escrow = new ChallengeEscrow(
            IERC20(address(usdc)), makeAddr("owner"), resolver, treasury, 500, 7 days, 1e6, 1_000e6
        );

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("p0");
        actors[1] = makeAddr("p1");
        actors[2] = makeAddr("p2");
        actors[3] = makeAddr("p3");
        handler = new EscrowHandler(escrow, usdc, resolver, actors);
        targetContract(address(handler));
    }

    /// The contract holds exactly what it owes: credited balances plus stakes still in play.
    function invariant_balanceEqualsLiabilities() public view {
        uint256 owed = escrow.credits(treasury);
        address[] memory actors = handler.actorsList();
        for (uint256 i; i < actors.length; ++i) {
            owed += escrow.credits(actors[i]);
        }
        uint256 last = escrow.nextId();
        for (uint256 id = 1; id < last; ++id) {
            ChallengeEscrow.Challenge memory c = escrow.getChallenge(id);
            if (c.status == ChallengeEscrow.Status.Open) owed += c.stake;
            else if (c.status == ChallengeEscrow.Status.Active) owed += 2 * uint256(c.stake);
        }
        assertEq(usdc.balanceOf(address(escrow)), owed);
    }

    /// Every token that came in is either still held or was withdrawn by its owner.
    function invariant_depositsConserved() public view {
        assertEq(handler.ghostDeposited(), usdc.balanceOf(address(escrow)) + handler.ghostWithdrawn());
    }

    /// The platform never takes more than MAX_FEE_BPS of settled pots.
    function invariant_feesBounded() public view {
        assertLe(handler.ghostFeesCredited() * 10_000, handler.ghostSettledPots() * escrow.MAX_FEE_BPS());
    }

    /// Nobody but players, the treasury, and the escrow ever holds tokens (resolver/owner can't extract).
    function invariant_resolverAndOwnerHoldNothing() public view {
        assertEq(usdc.balanceOf(escrow.resolver()), 0);
        assertEq(usdc.balanceOf(escrow.owner()), 0);
        assertEq(escrow.credits(escrow.resolver()), 0);
        assertEq(escrow.credits(escrow.owner()), 0);
    }

    /// Logs how often each action actually ran, to confirm the handler reaches every path (run with -vv).
    function afterInvariant() external view {
        string[7] memory actions =
            ["create", "accept", "cancel", "resolve", "resolveDraw", "refundExpired", "withdraw"];
        for (uint256 i; i < actions.length; ++i) {
            console.log(actions[i], handler.calls(bytes32(bytes(actions[i]))));
        }
    }
}
