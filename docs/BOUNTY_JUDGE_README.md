# Privacy-Preserving AI Bounty Judge — Homework Submission

Required track (commit-reveal) implemented in full, wired to the **real**
Ritual precompile architecture (confirmed from your project's own
`contracts/utils/PrecompileConsumer.sol`) rather than a made-up external
judge contract. Advanced track (Ritual-native hidden submissions) covered
as a design document — see `docs/ARCHITECTURE.md`.

## Why this exists

In the workshop version, `submitAnswer` stored plaintext answers directly on
chain, so anyone could read earlier submissions before the deadline and
resubmit an improved copy. This homework fixes that by making the
submission phase publish only a **commitment hash**; the plaintext answer
only becomes visible when the participant reveals it themselves, after the
submission window has already closed for everyone.

## Files

```
contracts/
  BountyJudge.sol            required-track contract
  utils/PrecompileConsumer.sol   (your existing file — unchanged, copied in for completeness)
  test/BountyJudgeHarness.sol    test-only subclass, see "Testing" below
test/
  BountyJudge.test.js         hardhat/mocha test suite
docs/
  ARCHITECTURE.md             commit-reveal vs Ritual-native comparison,
                               advanced-track design, reflection question
hardhat.config.js
package.json
```

**Drop these into your fork's `hardhat/` folder next to your existing
`contracts/BountyJudge.sol`, `contracts/mocks/`, and `contracts/utils/`** —
replace your current `BountyJudge.sol` with this one (it now inherits your
real `PrecompileConsumer`), and create the `test/` folder if it doesn't
exist yet.

## Lifecycle

1. **Create** — `createBounty(submissionDeadline, revealDeadline)` (payable).
   The owner locks the reward in the contract and sets both deadlines.
2. **Commit** (before `submissionDeadline`) — each participant calls
   `submitCommitment(bountyId, commitment)` where
   `commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))`.
   Only the hash is stored. One commitment per address per bounty.
3. **Reveal** (between `submissionDeadline` and `revealDeadline`) — each
   participant calls `revealAnswer(bountyId, answer, salt)`. The contract
   recomputes the hash and only accepts the reveal if it matches the stored
   commitment. Binding `msg.sender` and `bountyId` into the hash stops
   anyone from copying someone else's `(answer, salt)` pair and revealing it
   as their own.
4. **Judge** (after `revealDeadline`, owner only) — `judgeAll(bountyId,
   llmInput)` calls the **real Ritual precompiles synchronously, in the
   same transaction**:
   - `LLM_INFERENCE_PRECOMPILE` (`0x0802`) runs the batch judging prompt —
     one call covering every revealed answer, not one call per submission.
   - `JQ_PRECOMPILE` (`0x0803`) extracts `winnerIndex` from the LLM's JSON
     result on-chain.
   There is **no external judge contract and no async callback** — this
   matches how `PrecompileConsumer._executePrecompile` already decodes
   "short-running async" precompiles (LLM, HTTP, DKMS) inline, in the same
   call frame, per Ritual's docs.
5. **Finalize** (owner only) — `finalizeWinner(bountyId, winnerIndex)`
   checks the index against what `judgeAll` actually recorded and pays the
   reward. This is a deliberate extra step: the AI recommends inside
   `judgeAll`, a human confirms and pays in a separate transaction —
   `judgeAll` never auto-pays.

## Precompile wiring — two TODOs you must fill in

I don't have your exact `ritual-dapp-llm` / `ritual-dapp-precompiles` skill
docs in front of me, so I did **not** guess the exact ABI struct layout for
the LLM and JQ precompile requests (guessing wrong would silently break
grading). In `BountyJudge._judgeSubmissions`, there are two marked TODOs:

```solidity
function _judgeSubmissions(bytes calldata llmInput) internal virtual returns (uint256 winnerIndex, bytes memory rawOutput) {
    rawOutput = _executePrecompile(LLM_INFERENCE_PRECOMPILE, llmInput);

    // --- TODO: replace with the real JQ request encoding ---
    bytes memory jqRequest = abi.encode(rawOutput, ".winnerIndex");
    bytes memory jqResult = _executePrecompile(JQ_PRECOMPILE, jqRequest);
    winnerIndex = abi.decode(jqResult, (uint256));
    // ---------------------------------------------------------
}
```

Open `skills/ritual-dapp-llm/SKILL.md` and `skills/ritual-dapp-precompiles/SKILL.md`
in your own project (or the `ritual-dapp-skills` repo if you cloned it) and
confirm:
1. The exact struct Solidity must ABI-encode to call `LLM_INFERENCE_PRECOMPILE`
   — is `llmInput` (the homework's suggested parameter) already that full
   encoded request, or does the contract need to build it from a prompt +
   model name + the revealed answers?
2. The exact struct for `JQ_PRECOMPILE` and what its returned bytes decode
   into (is it raw bytes of a JSON scalar, an ABI-encoded uint256, a string
   you still need to `abi.decode`/`parseInt` off-chain?).

Everything else in the contract (commit-reveal, deadlines, access control,
payout, double-finalize protection) does **not** depend on getting these
two lines exactly right.

## Running the tests

```bash
npm install
npx hardhat test
```

> Precompiles `0x0802`/`0x0803` don't exist on a local Hardhat node, so unit
> tests use `contracts/test/BountyJudgeHarness.sol`, a subclass that
> overrides `_judgeSubmissions` with a value the test sets in advance
> (`setStubJudgingResult`). This lets every rule *except* the precompile
> encoding itself be tested locally. Test the real precompile calls against
> a Ritual devnet/testnet deployment before submitting, using the deadlines
> shortened for a quick manual run-through.

> Note: this sandbox has no network access, so this suite was written and
> manually reviewed but **not executed** in this environment — run it
> locally to confirm everything passes before you submit.

## Test plan (see `test/BountyJudge.test.js` for the executable version)

| # | Case | Expected |
|---|------|----------|
| 1 | Commit during submission phase | Succeeds, emits `CommitmentSubmitted` |
| 2 | Second commit from same address | Reverts `AlreadyCommitted` |
| 3 | Commit after submission deadline | Reverts `SubmissionPhaseOver` |
| 4 | Reveal before submission deadline | Reverts `NotInRevealPhase` |
| 5 | Reveal after reveal deadline | Reverts `NotInRevealPhase` |
| 6 | Reveal with wrong answer/salt | Reverts `CommitmentMismatch` |
| 7 | Third party tries to reveal someone else's commitment | Reverts `NoCommitmentFound` (sender is bound into the hash) |
| 8 | Commit but never reveal | Submission stays `revealed = false`, excluded from judging |
| 9 | `judgeAll` called by non-owner | Reverts `NotBountyOwner` |
| 10 | `judgeAll` called before reveal deadline | Reverts `RevealPhaseNotOver` |
| 11 | Judging result points at an unrevealed submission | Reverts `WinnerNotRevealed` |
| 12 | Full happy path: commit → reveal → judge → finalize | Winner is paid the exact reward |
| 13 | `finalizeWinner` called twice | Second call reverts `AlreadyFinalized` |
| 14 | `finalizeWinner` called before judging completes | Reverts `NotJudgedYet` |

