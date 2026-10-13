// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ChallengeEscrow
/// @notice Holds equal stakes from two players for a head-to-head challenge and releases them
///         according to an off-chain verdict. Everything except money lives off-chain.
/// @dev Design rules:
///      - The resolver can only pay one of the two players, or refund both. It can never send funds elsewhere.
///      - Every funded state has a deadline after which anyone can trigger a refund, so funds can't get stuck.
///      - All payouts are credited and withdrawn by the recipient (pull payments).
///      - Pausing blocks new challenges and acceptances only. Exits always work.
///      - Not upgradeable. Fixes ship as a new deployment.
contract ChallengeEscrow is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Open, // creator staked, waiting for an opponent
        Active, // both staked, waiting for a verdict
        Settled, // winner paid (minus fee)
        Drawn, // resolver declared a draw or void, both refunded
        Cancelled, // creator withdrew before anyone accepted
        Expired // deadline passed without acceptance or verdict, refunded
    }

    struct Challenge {
        address creator;
        uint96 stake; // per player, token base units
        address opponent; // while Open: invited opponent (0 = anyone). After accept: actual opponent.
        uint40 acceptBy; // last timestamp at which accept() succeeds
        uint40 resolveBy; // set on accept: last timestamp at which a verdict can be recorded
        uint16 feeBps; // snapshot at creation
        uint32 resolveWindow; // snapshot at creation; seconds from accept to resolveBy
        Status status;
    }

    uint16 public constant MAX_FEE_BPS = 1_000; // 10%
    uint32 public constant MAX_ACCEPT_WINDOW = 30 days;
    uint32 public constant MIN_RESOLVE_WINDOW = 1 days;
    uint32 public constant MAX_RESOLVE_WINDOW = 30 days;
    uint256 private constant BPS = 10_000;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IERC20 public immutable token;

    address public resolver;
    address public feeRecipient;
    uint16 public feeBps;
    uint32 public resolveWindow;
    uint96 public minStake;
    uint96 public maxStake;

    uint256 public nextId = 1;
    mapping(uint256 id => Challenge) private _challenges;
    mapping(address account => uint256 amount) public credits;

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

    event ResolverUpdated(address indexed resolver);
    event FeeRecipientUpdated(address indexed feeRecipient);
    event FeeBpsUpdated(uint16 feeBps);
    event ResolveWindowUpdated(uint32 resolveWindow);
    event StakeLimitsUpdated(uint96 minStake, uint96 maxStake);

    error ZeroAddress();
    error InvalidStake();
    error InvalidAcceptBy();
    error InvalidOpponent();
    error InvalidWinner();
    error InvalidStatus();
    error NotCreator();
    error NotResolver();
    error NotInvited();
    error ResolverCannotPlay();
    error DeadlinePassed();
    error NotExpired();
    error FeeTooHigh();
    error InvalidResolveWindow();
    error InvalidStakeLimits();
    error UnexpectedTransferAmount();
    error NothingToWithdraw();

    modifier onlyResolver() {
        _checkResolver();
        _;
    }

    constructor(
        IERC20 token_,
        address owner_,
        address resolver_,
        address feeRecipient_,
        uint16 feeBps_,
        uint32 resolveWindow_,
        uint96 minStake_,
        uint96 maxStake_
    ) Ownable(owner_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
        _setResolver(resolver_);
        _setFeeRecipient(feeRecipient_);
        _setFeeBps(feeBps_);
        _setResolveWindow(resolveWindow_);
        _setStakeLimits(minStake_, maxStake_);
    }

    // ---------------------------------------------------------------------
    // Player actions
    // ---------------------------------------------------------------------

    /// @notice Create a challenge and deposit the creator's stake. Requires prior `approve`.
    /// @param invitedOpponent Address allowed to accept, or address(0) for an open challenge.
    /// @param rulesHash Hash of the off-chain challenge terms (game, objective, rules, DB id).
    function create(uint96 stake, uint40 acceptBy, address invitedOpponent, bytes32 rulesHash)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 id)
    {
        if (stake < minStake || stake > maxStake) revert InvalidStake();
        if (acceptBy <= block.timestamp || acceptBy > block.timestamp + MAX_ACCEPT_WINDOW) {
            revert InvalidAcceptBy();
        }
        if (invitedOpponent == msg.sender || (invitedOpponent != address(0) && invitedOpponent == resolver)) {
            revert InvalidOpponent();
        }
        if (msg.sender == resolver) revert ResolverCannotPlay();

        id = nextId++;
        _challenges[id] = Challenge({
            creator: msg.sender,
            stake: stake,
            opponent: invitedOpponent,
            acceptBy: acceptBy,
            resolveBy: 0,
            feeBps: feeBps,
            resolveWindow: resolveWindow,
            status: Status.Open
        });

        emit ChallengeCreated(
            id, msg.sender, invitedOpponent, stake, acceptBy, feeBps, resolveWindow, rulesHash
        );
        _pullStake(msg.sender, stake);
    }

    /// @notice Creator cancels an unaccepted challenge and gets their stake credited back.
    function cancel(uint256 id) external nonReentrant {
        Challenge storage c = _challenges[id];
        if (c.status != Status.Open) revert InvalidStatus();
        if (msg.sender != c.creator) revert NotCreator();

        c.status = Status.Cancelled;
        credits[c.creator] += c.stake;
        emit ChallengeCancelled(id);
    }

    /// @notice Accept an open challenge by depositing a matching stake. Requires prior `approve`.
    function accept(uint256 id) external nonReentrant whenNotPaused {
        Challenge storage c = _challenges[id];
        if (c.status != Status.Open) revert InvalidStatus();
        if (block.timestamp > c.acceptBy) revert DeadlinePassed();
        if (msg.sender == c.creator) revert InvalidOpponent();
        if (msg.sender == resolver) revert ResolverCannotPlay();
        if (c.opponent != address(0) && msg.sender != c.opponent) revert NotInvited();

        uint40 resolveBy = uint40(block.timestamp) + c.resolveWindow;
        c.opponent = msg.sender;
        c.resolveBy = resolveBy;
        c.status = Status.Active;

        emit ChallengeAccepted(id, msg.sender, resolveBy);
        _pullStake(msg.sender, c.stake);
    }

    /// @notice Withdraw everything credited to the caller (winnings and refunds).
    function withdraw() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        credits[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }

    /// @notice Refund a challenge whose deadline passed. Callable by anyone.
    ///         Open past acceptBy: refunds the creator. Active past resolveBy: refunds both players.
    function refundExpired(uint256 id) external nonReentrant {
        Challenge storage c = _challenges[id];
        if (c.status == Status.Open) {
            if (block.timestamp <= c.acceptBy) revert NotExpired();
            credits[c.creator] += c.stake;
        } else if (c.status == Status.Active) {
            if (block.timestamp <= c.resolveBy) revert NotExpired();
            credits[c.creator] += c.stake;
            credits[c.opponent] += c.stake;
        } else {
            revert InvalidStatus();
        }
        c.status = Status.Expired;
        emit ChallengeExpired(id);
    }

    // ---------------------------------------------------------------------
    // Resolver actions
    // ---------------------------------------------------------------------

    /// @notice Record a winner. Credits the winner with the pot minus the fee.
    /// @param evidenceHash Hash of the off-chain evidence and verdict (video hashes, measured times).
    function resolve(uint256 id, address winner, bytes32 evidenceHash) external nonReentrant onlyResolver {
        Challenge storage c = _requireResolvable(id);
        if (winner != c.creator && winner != c.opponent) revert InvalidWinner();

        uint256 pot = uint256(c.stake) * 2;
        uint256 fee = (pot * c.feeBps) / BPS;
        uint256 payout = pot - fee;

        c.status = Status.Settled;
        credits[winner] += payout;
        if (fee != 0) credits[feeRecipient] += fee;
        emit ChallengeSettled(id, winner, payout, fee, evidenceHash);
    }

    /// @notice Record a draw or void verdict. Both players get their stake back, no fee.
    function resolveDraw(uint256 id, bytes32 evidenceHash) external nonReentrant onlyResolver {
        Challenge storage c = _requireResolvable(id);
        c.status = Status.Drawn;
        credits[c.creator] += c.stake;
        credits[c.opponent] += c.stake;
        emit ChallengeDrawn(id, evidenceHash);
    }

    // ---------------------------------------------------------------------
    // Owner configuration (affects new challenges only)
    // ---------------------------------------------------------------------

    function setResolver(address resolver_) external onlyOwner {
        _setResolver(resolver_);
    }

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        _setFeeRecipient(feeRecipient_);
    }

    function setFeeBps(uint16 feeBps_) external onlyOwner {
        _setFeeBps(feeBps_);
    }

    function setResolveWindow(uint32 resolveWindow_) external onlyOwner {
        _setResolveWindow(resolveWindow_);
    }

    function setStakeLimits(uint96 minStake_, uint96 maxStake_) external onlyOwner {
        _setStakeLimits(minStake_, maxStake_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getChallenge(uint256 id) external view returns (Challenge memory) {
        return _challenges[id];
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _checkResolver() private view {
        if (msg.sender != resolver) revert NotResolver();
    }

    function _requireResolvable(uint256 id) private view returns (Challenge storage c) {
        c = _challenges[id];
        if (c.status != Status.Active) revert InvalidStatus();
        if (block.timestamp > c.resolveBy) revert DeadlinePassed();
    }

    /// @dev Rejects tokens that deliver less than requested (fee-on-transfer), which would break accounting.
    function _pullStake(address from, uint256 amount) private {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) - before != amount) revert UnexpectedTransferAmount();
    }

    function _setResolver(address resolver_) private {
        if (resolver_ == address(0)) revert ZeroAddress();
        resolver = resolver_;
        emit ResolverUpdated(resolver_);
    }

    function _setFeeRecipient(address feeRecipient_) private {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        emit FeeRecipientUpdated(feeRecipient_);
    }

    function _setFeeBps(uint16 feeBps_) private {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeBpsUpdated(feeBps_);
    }

    function _setResolveWindow(uint32 resolveWindow_) private {
        if (resolveWindow_ < MIN_RESOLVE_WINDOW || resolveWindow_ > MAX_RESOLVE_WINDOW) {
            revert InvalidResolveWindow();
        }
        resolveWindow = resolveWindow_;
        emit ResolveWindowUpdated(resolveWindow_);
    }

    function _setStakeLimits(uint96 minStake_, uint96 maxStake_) private {
        if (minStake_ == 0 || minStake_ > maxStake_) revert InvalidStakeLimits();
        minStake = minStake_;
        maxStake = maxStake_;
        emit StakeLimitsUpdated(minStake_, maxStake_);
    }
}
