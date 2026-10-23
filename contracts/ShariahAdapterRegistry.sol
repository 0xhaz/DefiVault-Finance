// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title  ShariahAdapterRegistry
 * @notice Governance-gated registry of Shariah-screened strategy adapters.
 *
 * ## Design
 * Every screening entry carries a `pronouncementHash` (keccak256 of the board
 * resolution document) and an `expiresAt` timestamp.  ShariahVaultV2 queries
 * this registry before any capital deployment.
 *
 * ## Timelock
 * All add/update/remove operations must be *proposed* first, then *executed*
 * after `TIMELOCK_PERIOD` has elapsed.  This prevents any single actor from
 * silently slip-streaming an unscreened adapter.
 *
 * ## Roles
 * - `BOARD_ROLE`   : can propose and execute screening changes
 * - `owner`        : can grant/revoke BOARD_ROLE (Ownable)
 *
 * @dev    SR-005 through SR-011 are cited per adapter — see docs/agents/SHARIAH_REVIEW.md.
 */
contract ShariahAdapterRegistry is Ownable {

    // ─────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────

    /// @notice Minimum time between a proposal and its execution.
    uint256 public constant TIMELOCK_PERIOD = 30 days;

    /// @notice Maximum screening validity period (prevents stale entries).
    uint256 public constant MAX_EXPIRY_PERIOD = 730 days; // 2 years

    // ─────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────

    error NotBoardRole(address caller);
    error TimelockNotElapsed(uint256 earliest, uint256 current);
    error NoPendingProposal(address adapter);
    error AlreadyProposed(address adapter);
    error ExpiryTooFar(uint256 expiresAt, uint256 maxAllowed);
    error ZeroHash();
    error ZeroAdapter();

    // ─────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────

    event BoardRoleGranted(address indexed account);
    event BoardRoleRevoked(address indexed account);
    event BoardRoleChangeProposed(address indexed account, bool grant, uint256 executeAfter);
    event BoardRoleChangeCancelled(address indexed account);
    event ScreeningProposed(address indexed adapter, bytes32 pronouncementHash, uint256 expiresAt, uint256 executeAfter);
    event ScreeningExecuted(address indexed adapter, bytes32 pronouncementHash, uint256 expiresAt);
    event ScreeningRemoved(address indexed adapter);
    event RemovalProposed(address indexed adapter, uint256 executeAfter);
    event RemovalExecuted(address indexed adapter);

    // ─────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────

    struct Screening {
        /// @notice keccak256 of the board resolution document. Zero = not screened.
        bytes32 pronouncementHash;
        /// @notice Unix timestamp after which this screening expires (re-review required).
        uint256 expiresAt;
        /// @notice Block timestamp when the screening was last set.
        uint256 setAt;
    }

    struct Proposal {
        bytes32 pronouncementHash;
        uint256 expiresAt;
        /// @notice Earliest timestamp at which this proposal may be executed.
        uint256 executeAfter;
        bool    exists;
    }

    /// @notice Board members who can propose + execute screening changes.
    mapping(address => bool) public boardRole;

    struct BoardRoleProposal {
        bool grant;           // true = grant, false = revoke
        uint256 executeAfter;
        bool exists;
    }

    /// @notice Pending board-role change proposals. Proposed by board, executed after timelock.
    /// @dev    G4 fix: owner cannot unilaterally grant/revoke board membership.
    ///         A board member must propose; any board member (or proposer) can execute after delay.
    mapping(address => BoardRoleProposal) public boardRoleProposals;

    /// @notice Active screenings — the live registry.
    mapping(address => Screening) public screenings;

    /// @notice Pending proposals (add/update).
    mapping(address => Proposal) public proposals;

    /// @notice Pending removal proposals.
    mapping(address => uint256) public removalProposals; // adapter → executeAfter (0 = none)

    // ─────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────

    modifier onlyBoard() {
        if (!boardRole[msg.sender]) revert NotBoardRole(msg.sender);
        _;
    }

    // ─────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────

    /// @param initialOwner       Contract owner (Ownable2Step pattern). Can emergency-revoke
    ///                           board members. Does NOT automatically receive boardRole (I5).
    /// @param initialBoardMember The multisig or board address that receives boardRole at deploy.
    ///                           Pass a safe/multisig — not the deployer EOA — to satisfy the
    ///                           H PR2.2 / I5 requirement that the deployer is not sole board.
    ///                           May equal initialOwner only when no separate multisig is available
    ///                           (e.g. testnet single-signer setup); document the risk in README.
    constructor(address initialOwner, address initialBoardMember) Ownable(initialOwner) {
        boardRole[initialBoardMember] = true;
        emit BoardRoleGranted(initialBoardMember);
    }

    // ─────────────────────────────────────────────────────────────
    // Role management
    // ─────────────────────────────────────────────────────────────

    // ─────────────────────────────────────────────────────────────
    // Board role management — G4 fix
    // ─────────────────────────────────────────────────────────────
    // Grant and revoke require a board member to propose + 30-day timelock.
    // The owner retains only pause-level rights and cannot self-appoint.
    // ─────────────────────────────────────────────────────────────

    error BoardRoleProposalExists(address account);
    error NoBoardRoleProposal(address account);

    /// @notice A board member proposes granting or revoking board membership.
    ///         Owner alone cannot propose — only an existing board member can.
    function proposeBoardRoleChange(address account, bool grant) external onlyBoard {
        if (boardRoleProposals[account].exists) revert BoardRoleProposalExists(account);
        uint256 executeAfter = block.timestamp + TIMELOCK_PERIOD;
        boardRoleProposals[account] = BoardRoleProposal({grant: grant, executeAfter: executeAfter, exists: true});
        emit BoardRoleChangeProposed(account, grant, executeAfter);
    }

    /// @notice Any board member may execute a pending board-role change after the timelock.
    function executeBoardRoleChange(address account) external onlyBoard {
        BoardRoleProposal memory p = boardRoleProposals[account];
        if (!p.exists) revert NoBoardRoleProposal(account);
        if (block.timestamp < p.executeAfter) revert TimelockNotElapsed(p.executeAfter, block.timestamp);
        delete boardRoleProposals[account];
        boardRole[account] = p.grant;
        if (p.grant) emit BoardRoleGranted(account);
        else         emit BoardRoleRevoked(account);
    }

    /// @notice Cancel a pending board-role proposal.
    function cancelBoardRoleChange(address account) external onlyBoard {
        if (!boardRoleProposals[account].exists) revert NoBoardRoleProposal(account);
        delete boardRoleProposals[account];
        emit BoardRoleChangeCancelled(account);
    }

    /// @notice Owner-only emergency: revoke a board member immediately (pause power).
    /// @dev    Intentionally asymmetric: owner can remove but not add without the board.
    ///         This prevents a rogue board member from being impossible to remove.
    function emergencyRevokeBoardRole(address account) external onlyOwner {
        boardRole[account] = false;
        emit BoardRoleRevoked(account);
    }

    // ─────────────────────────────────────────────────────────────
    // Screening — propose / execute (add or update)
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Propose a new or updated screening for an adapter.
     * @param adapter           Address of the strategy adapter.
     * @param pronouncementHash keccak256 of the board resolution document.
     * @param expiresAt         Screening expiry (unix seconds). Max 2 years out.
     */
    function proposeScreening(
        address adapter,
        bytes32 pronouncementHash,
        uint256 expiresAt
    ) external onlyBoard {
        if (adapter == address(0))         revert ZeroAdapter();
        if (pronouncementHash == bytes32(0)) revert ZeroHash();
        if (proposals[adapter].exists)     revert AlreadyProposed(adapter);
        if (expiresAt > block.timestamp + MAX_EXPIRY_PERIOD)
            revert ExpiryTooFar(expiresAt, block.timestamp + MAX_EXPIRY_PERIOD);

        uint256 executeAfter = block.timestamp + TIMELOCK_PERIOD;
        proposals[adapter] = Proposal({
            pronouncementHash: pronouncementHash,
            expiresAt:         expiresAt,
            executeAfter:      executeAfter,
            exists:            true
        });

        emit ScreeningProposed(adapter, pronouncementHash, expiresAt, executeAfter);
    }

    /**
     * @notice Execute a previously proposed screening after the timelock has elapsed.
     */
    function executeScreening(address adapter) external onlyBoard {
        Proposal memory p = proposals[adapter];
        if (!p.exists) revert NoPendingProposal(adapter);
        if (block.timestamp < p.executeAfter)
            revert TimelockNotElapsed(p.executeAfter, block.timestamp);

        screenings[adapter] = Screening({
            pronouncementHash: p.pronouncementHash,
            expiresAt:         p.expiresAt,
            setAt:             block.timestamp
        });
        delete proposals[adapter];

        emit ScreeningExecuted(adapter, p.pronouncementHash, p.expiresAt);
    }

    /**
     * @notice Cancel a pending proposal before it is executed.
     */
    function cancelProposal(address adapter) external onlyBoard {
        if (!proposals[adapter].exists) revert NoPendingProposal(adapter);
        delete proposals[adapter];
    }

    // ─────────────────────────────────────────────────────────────
    // Removal — propose / execute
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Propose removal of a screened adapter.
     */
    function proposeRemoval(address adapter) external onlyBoard {
        if (adapter == address(0)) revert ZeroAdapter();
        uint256 executeAfter = block.timestamp + TIMELOCK_PERIOD;
        removalProposals[adapter] = executeAfter;
        emit RemovalProposed(adapter, executeAfter);
    }

    /**
     * @notice Execute a pending removal after the timelock has elapsed.
     */
    function executeRemoval(address adapter) external onlyBoard {
        uint256 executeAfter = removalProposals[adapter];
        if (executeAfter == 0) revert NoPendingProposal(adapter);
        if (block.timestamp < executeAfter)
            revert TimelockNotElapsed(executeAfter, block.timestamp);

        delete screenings[adapter];
        delete removalProposals[adapter];
        emit RemovalExecuted(adapter);
    }

    // ─────────────────────────────────────────────────────────────
    // Read helpers
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Returns true only when the adapter is screened AND the screening
     *         has not expired.  ShariahVaultV2 calls this before deployCapital.
     */
    function isScreened(address adapter) external view returns (bool) {
        Screening memory s = screenings[adapter];
        return s.pronouncementHash != bytes32(0) && block.timestamp < s.expiresAt;
    }

    /**
     * @notice Returns the full Screening struct for an adapter.
     */
    function getScreening(address adapter) external view returns (Screening memory) {
        return screenings[adapter];
    }

    /**
     * @notice Single-source board membership query (I4).
     *         CharityModule and PurificationEscrow call this instead of maintaining
     *         their own local boardRole mappings, so governance changes propagate to
     *         all contracts simultaneously.
     */
    function isBoard(address account) external view returns (bool) {
        return boardRole[account];
    }
}
