// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../BountyJudge.sol";

/// @notice Test-only subclass of BountyJudge. Local Hardhat/Anvil nodes
/// don't have the real Ritual precompiles deployed at 0x0802/0x0803, so we
/// can't call judgeAll() against production code in a unit test. Instead,
/// this harness overrides `_judgeSubmissions` with a value the test sets in
/// advance, so every OTHER rule (deadlines, access control, commit-reveal
/// correctness, payout, double-finalize protection...) can still be
/// exercised end-to-end without a live TEE executor.
///
/// Precompile wiring itself (the two TODOs in BountyJudge._judgeSubmissions)
/// should be checked separately against a Ritual testnet/devnet, per the
/// `ritual-dapp-testing` skill's guidance on precompile mocking.
contract BountyJudgeHarness is BountyJudge {
    uint256 private _stubWinnerIndex;
    bytes private _stubRawOutput;
    bool private _stubSet;

    /// @notice Configure what the next judgeAll() call should "receive back"
    /// from the (stubbed) LLM + JQ precompile chain.
    function setStubJudgingResult(uint256 winnerIndex, bytes calldata rawOutput) external {
        _stubWinnerIndex = winnerIndex;
        _stubRawOutput = rawOutput;
        _stubSet = true;
    }

    function _judgeSubmissions(bytes calldata /* llmInput */) internal override returns (uint256 winnerIndex, bytes memory rawOutput) {
        require(_stubSet, "call setStubJudgingResult first");
        _stubSet = false; // consume the stub so each judgeAll() call needs an explicit setup
        return (_stubWinnerIndex, _stubRawOutput);
    }
}

