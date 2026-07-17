// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./utils/PrecompileConsumer.sol";

/// @title BountyJudge
/// @notice Privacy-preserving AI Bounty Judge using a commit-reveal scheme.
/// Answers are hidden as commitments during the submission phase and only
/// become public during the reveal phase, so later participants can no
/// longer read and copy earlier answers before the deadline.
///
/// Judging calls the real Ritual precompiles synchronously (same
/// transaction, same call frame) instead of a separate external judge
/// contract + async callback: LLM_INFERENCE_PRECOMPILE (0x0802) produces a
/// JSON judging result, JQ_PRECOMPILE (0x0803) extracts the winner index
/// from that JSON on-chain. See README "Precompile wiring" section for the
/// two exact encoding TODOs you must fill in from your own copy of the
/// ritual-dapp-llm / ritual-dapp-precompiles skill docs.
contract BountyJudge is PrecompileConsumer {
    // ---------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------

    enum BountyState {
        Open, // accepting commitments / reveals
        Judged, // AI judging complete, ranking recorded
        Finalized // winner paid
    }

    struct Bounty {
        address owner;
        uint256 reward;
        uint256 submissionDeadline;
        uint256 revealDeadline;
        BountyState state;
        uint256 winnerIndex;
        bool winnerSet;
        bytes32 judgingOutputHash; // keccak256 of the raw LLM judging output
        address[] participants; // insertion order == index used by the judge/finalizer
    }

    struct Submission {
        bytes32 commitment;
        bool revealed;
        string answer; // empty until revealed
    }

    // ---------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------

    uint256 public bountyCount;

    mapping(uint256 => Bounty) private bounties;
    // bountyId => participant => submission
    mapping(uint256 => mapping(address => Submission)) private submissions;
    // bountyId => participant => hasCommitted (redundant guard, kept explicit for clarity)
    mapping(uint256 => mapping(address => bool)) public hasCommitted;

    // ---------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------

    event BountyCreated(uint256 indexed bountyId, address indexed owner, uint256 reward, uint256 submissionDeadline, uint256 revealDeadline);
    event CommitmentSubmitted(uint256 indexed bountyId, address indexed participant, bytes32 commitment);
    event AnswerRevealed(uint256 indexed bountyId, address indexed participant, uint256 index);
    /// @dev Full raw judging output is emitted (not stored) so anyone can
    /// re-derive and check it against `judgingOutputHash` off-chain without
    /// the contract paying storage gas for a potentially large JSON blob.
    event BountyJudged(uint256 indexed bountyId, uint256 winnerIndex, bytes32 judgingOutputHash, bytes judgingOutput);
    event WinnerFinalized(uint256 indexed bountyId, address indexed winner, uint256 reward);

    // ---------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------

    error SubmissionPhaseOver();
    error NotInRevealPhase();
    error RevealPhaseNotOver();
    error AlreadyCommitted();
    error NoCommitmentFound();
    error CommitmentMismatch();
    error AlreadyRevealed();
    error NotBountyOwner();
    error NotJudgedYet();
    error AlreadyJudged();
    error AlreadyFinalized();
    error InvalidWinnerIndex();
    error WinnerNotRevealed();
    error TransferFailed();

    // ---------------------------------------------------------------
    // Bounty creation
    // ---------------------------------------------------------------

    function createBounty(uint256 submissionDeadline, uint256 revealDeadline) external payable returns (uint256 bountyId) {
        require(submissionDeadline > block.timestamp, "submission deadline in past");
        require(revealDeadline > submissionDeadline, "reveal deadline must be after submission deadline");
        require(msg.value > 0, "reward required");

        bountyId = bountyCount++;
        Bounty storage b = bounties[bountyId];
        b.owner = msg.sender;
        b.reward = msg.value;
        b.submissionDeadline = submissionDeadline;
        b.revealDeadline = revealDeadline;
        b.state = BountyState.Open;

        emit BountyCreated(bountyId, msg.sender, msg.value, submissionDeadline, revealDeadline);
    }

    // ---------------------------------------------------------------
    // Required Track: Commit-Reveal
    // ---------------------------------------------------------------

    /// @notice Submit only a hash of your answer. The plaintext answer is
    /// never sent to the contract at this stage, so nobody — not other
    /// participants, not indexers, not the bounty owner — can read it.
    function submitCommitment(uint256 bountyId, bytes32 commitment) external {
        Bounty storage b = bounties[bountyId];
        if (block.timestamp >= b.submissionDeadline) revert SubmissionPhaseOver();
        if (hasCommitted[bountyId][msg.sender]) revert AlreadyCommitted();

        hasCommitted[bountyId][msg.sender] = true;
        submissions[bountyId][msg.sender] = Submission({commitment: commitment, revealed: false, answer: ""});
        b.participants.push(msg.sender);

        emit CommitmentSubmitted(bountyId, msg.sender, commitment);
    }

    /// @notice Reveal the answer + salt behind an earlier commitment. Only
    /// valid between submissionDeadline and revealDeadline, and only the
    /// original committer can reveal (commitment binds msg.sender).
    function revealAnswer(uint256 bountyId, string calldata answer, bytes32 salt) external {
        Bounty storage b = bounties[bountyId];
        if (block.timestamp < b.submissionDeadline || block.timestamp >= b.revealDeadline) revert NotInRevealPhase();

        Submission storage s = submissions[bountyId][msg.sender];
        if (s.commitment == bytes32(0)) revert NoCommitmentFound();
        if (s.revealed) revert AlreadyRevealed();

        bytes32 expected = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId));
        if (expected != s.commitment) revert CommitmentMismatch();

        s.revealed = true;
        s.answer = answer;

        emit AnswerRevealed(bountyId, msg.sender, _indexOf(b, msg.sender));
    }

    /// @notice Owner triggers exactly one batch judging call covering every
    /// revealed answer. `llmInput` must already be the fully-encoded
    /// LLM_INFERENCE_PRECOMPILE request (built off-chain from all revealed
    /// answers + the rubric — see homework "Example Final Output Shape").
    /// This is a SINGLE precompile call for the whole bounty, never one
    /// call per submission.
    function judgeAll(uint256 bountyId, bytes calldata llmInput) external {
        Bounty storage b = bounties[bountyId];
        if (msg.sender != b.owner) revert NotBountyOwner();
        if (block.timestamp < b.revealDeadline) revert RevealPhaseNotOver();
        if (b.state != BountyState.Open) revert AlreadyJudged();

        (uint256 winnerIndex, bytes memory rawOutput) = _judgeSubmissions(llmInput);

        if (winnerIndex >= b.participants.length) revert InvalidWinnerIndex();
        address winnerCandidate = b.participants[winnerIndex];
        if (!submissions[bountyId][winnerCandidate].revealed) revert WinnerNotRevealed();

        b.state = BountyState.Judged;
        b.winnerIndex = winnerIndex;
        b.winnerSet = true;
        b.judgingOutputHash = keccak256(rawOutput);

        emit BountyJudged(bountyId, winnerIndex, b.judgingOutputHash, rawOutput);
    }

    /// @dev Production judging path: calls the real Ritual precompiles.
    /// Split out as `virtual` so tests can override it with a deterministic
    /// stub instead of needing 0x0802/0x0803 to exist on a local Hardhat
    /// node (see contracts/test/BountyJudgeHarness.sol).
    ///
    /// TODO (fill in from your own `ritual-dapp-llm` / `ritual-dapp-precompiles`
    /// skill docs before deploying — the exact struct layout for the LLM
    /// and JQ precompile requests is NOT guessed here):
    ///   1. Confirm `llmInput` is already ABI-encoded exactly the way
    ///      LLM_INFERENCE_PRECOMPILE (0x0802) expects.
    ///   2. Confirm how to build the JQ_PRECOMPILE (0x0803) request that
    ///      extracts `.winnerIndex` from the LLM's JSON text output, and
    ///      how the JQ result bytes decode back into a uint256.
    function _judgeSubmissions(bytes calldata llmInput) internal virtual returns (uint256 winnerIndex, bytes memory rawOutput) {
        rawOutput = _executePrecompile(LLM_INFERENCE_PRECOMPILE, llmInput);

        // --- TODO: replace with the real JQ request encoding ---
        bytes memory jqRequest = abi.encode(rawOutput, ".winnerIndex");
        bytes memory jqResult = _executePrecompile(JQ_PRECOMPILE, jqRequest);
        winnerIndex = abi.decode(jqResult, (uint256));
        // ---------------------------------------------------------
    }

    /// @notice Owner confirms the winner and pays the reward. Kept as a
    /// separate step from judgeAll so a human always reviews the AI's
    /// recommendation (and the emitted raw judging output) before funds
    /// move — AI recommends, a human pays.
    function finalizeWinner(uint256 bountyId, uint256 winnerIndex) external {
        Bounty storage b = bounties[bountyId];
        if (msg.sender != b.owner) revert NotBountyOwner();
        if (b.state == BountyState.Finalized) revert AlreadyFinalized();
        if (b.state != BountyState.Judged) revert NotJudgedYet();
        if (winnerIndex != b.winnerIndex) revert InvalidWinnerIndex();

        b.state = BountyState.Finalized;
        address winner = b.participants[winnerIndex];
        uint256 reward = b.reward;

        (bool ok, ) = payable(winner).call{value: reward}("");
        if (!ok) revert TransferFailed();

        emit WinnerFinalized(bountyId, winner, reward);
    }

    // ---------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------

    function getBounty(uint256 bountyId)
        external
        view
        returns (
            address owner,
            uint256 reward,
            uint256 submissionDeadline,
            uint256 revealDeadline,
            BountyState state,
            uint256 participantCount
        )
    {
        Bounty storage b = bounties[bountyId];
        return (b.owner, b.reward, b.submissionDeadline, b.revealDeadline, b.state, b.participants.length);
    }

    function getParticipant(uint256 bountyId, uint256 index) external view returns (address) {
        return bounties[bountyId].participants[index];
    }

    function getSubmission(uint256 bountyId, address participant)
        external
        view
        returns (bytes32 commitment, bool revealed, string memory answer)
    {
        Submission storage s = submissions[bountyId][participant];
        // Plaintext answer is only returned once revealed — before that,
        // `answer` is empty regardless of what msg.sender queries.
        return (s.commitment, s.revealed, s.answer);
    }

    function _indexOf(Bounty storage b, address participant) private view returns (uint256) {
        uint256 len = b.participants.length;
        for (uint256 i = 0; i < len; i++) {
            if (b.participants[i] == participant) return i;
        }
        revert("participant not found");
    }
}
