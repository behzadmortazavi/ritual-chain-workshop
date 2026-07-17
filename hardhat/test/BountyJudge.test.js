// Hardhat 3 (node:test + viem) style test file — matches this project's
// actual test runner ("Running node:test tests" in `npx hardhat test`
// output), not the older Hardhat 2 / Mocha / ethers.js style.
import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { network } from "hardhat";
import { keccak256, encodePacked, parseEther, stringToHex } from "viem";

const { viem, networkHelpers } = await network.create();

// BountyJudgeHarness (contracts/test/BountyJudgeHarness.sol) overrides the
// real precompile calls with a stub, since 0x0802 (LLM) / 0x0803 (JQ) don't
// exist on a local Hardhat simulated network. Everything except the
// precompile wiring itself is exercised end-to-end here.

const saltA = keccak256(stringToHex("salt-1"));
const saltB = keccak256(stringToHex("salt-2"));

function commitmentFor(answer, saltValue, senderAddress, bountyId) {
  return keccak256(
    encodePacked(["string", "bytes32", "address", "uint256"], [answer, saltValue, senderAddress, bountyId])
  );
}

describe("BountyJudge (commit-reveal)", function () {
  let bountyJudge;
  let owner, alice, bob, mallory;
  let publicClient;

  beforeEach(async function () {
    [owner, alice, bob, mallory] = await viem.getWalletClients();
    publicClient = await viem.getPublicClient();
    bountyJudge = await viem.deployContract("BountyJudgeHarness");
  });

  async function createBounty() {
    const now = BigInt(await networkHelpers.time.latest());
    const submissionDeadline = now + 3600n; // +1h
    const revealDeadline = submissionDeadline + 3600n; // +2h
    await bountyJudge.write.createBounty([submissionDeadline, revealDeadline], {
      value: parseEther("1"),
    });
    return { bountyId: 0n, submissionDeadline, revealDeadline };
  }

  it("accepts a commitment during the submission phase", async function () {
    const { bountyId } = await createBounty();
    const commitment = commitmentFor("my answer", saltA, alice.account.address, bountyId);

    await viem.assertions.emitWithArgs(
      bountyJudge.write.submitCommitment([bountyId, commitment], { account: alice.account.address }),
      bountyJudge,
      "CommitmentSubmitted",
      [bountyId, alice.account.address, commitment]
    );
  });

  it("rejects a second commitment from the same participant", async function () {
    const { bountyId } = await createBounty();
    const commitment = commitmentFor("answer A", saltA, alice.account.address, bountyId);
    await bountyJudge.write.submitCommitment([bountyId, commitment], { account: alice.account.address });

    const commitment2 = commitmentFor("answer B", saltB, alice.account.address, bountyId);
    await viem.assertions.revertWithCustomError(
      bountyJudge.write.submitCommitment([bountyId, commitment2], { account: alice.account.address }),
      bountyJudge,
      "AlreadyCommitted"
    );
  });

  it("rejects commitments submitted after the submission deadline", async function () {
    const { bountyId, submissionDeadline } = await createBounty();
    await networkHelpers.time.increaseTo(submissionDeadline + 1n);

    const commitment = commitmentFor("too late", saltA, alice.account.address, bountyId);
    await viem.assertions.revertWithCustomError(
      bountyJudge.write.submitCommitment([bountyId, commitment], { account: alice.account.address }),
      bountyJudge,
      "SubmissionPhaseOver"
    );
  });

  it("rejects a reveal before the submission deadline has passed", async function () {
    const { bountyId } = await createBounty();
    const commitment = commitmentFor("my answer", saltA, alice.account.address, bountyId);
    await bountyJudge.write.submitCommitment([bountyId, commitment], { account: alice.account.address });

    await viem.assertions.revertWithCustomError(
      bountyJudge.write.revealAnswer([bountyId, "my answer", saltA], { account: alice.account.address }),
      bountyJudge,
      "NotInRevealPhase"
    );
  });

  it("rejects a reveal after the reveal deadline", async function () {
    const { bountyId, revealDeadline } = await createBounty();
    const commitment = commitmentFor("my answer", saltA, alice.account.address, bountyId);
    await bountyJudge.write.submitCommitment([bountyId, commitment], { account: alice.account.address });

    await networkHelpers.time.increaseTo(revealDeadline + 1n);
    await viem.assertions.revertWithCustomError(
      bountyJudge.write.revealAnswer([bountyId, "my answer", saltA], { account: alice.account.address }),
      bountyJudge,
      "NotInRevealPhase"
    );
  });

  it("rejects a reveal whose hash does not match the commitment", async function () {
    const { bountyId, submissionDeadline } = await createBounty();
    const commitment = commitmentFor("my real answer", saltA, alice.account.address, bountyId);
    await bountyJudge.write.submitCommitment([bountyId, commitment], { account: alice.account.address });

    await networkHelpers.time.increaseTo(submissionDeadline + 1n);
    await viem.assertions.revertWithCustomError(
      bountyJudge.write.revealAnswer([bountyId, "a different answer", saltA], { account: alice.account.address }),
      bountyJudge,
      "CommitmentMismatch"
    );
  });

  it("prevents mallory from revealing alice's commitment (sender is bound into the hash)", async function () {
    const { bountyId, submissionDeadline } = await createBounty();
    const commitment = commitmentFor("alice's answer", saltA, alice.account.address, bountyId);
    await bountyJudge.write.submitCommitment([bountyId, commitment], { account: alice.account.address });

    await networkHelpers.time.increaseTo(submissionDeadline + 1n);
    await viem.assertions.revertWithCustomError(
      bountyJudge.write.revealAnswer([bountyId, "alice's answer", saltA], { account: mallory.account.address }),
      bountyJudge,
      "NoCommitmentFound"
    );
  });

  it("marks unrevealed commitments as ineligible (they are simply absent from the ranking)", async function () {
    const { bountyId, submissionDeadline } = await createBounty();
    const commitmentAlice = commitmentFor("alice's answer", saltA, alice.account.address, bountyId);
    const commitmentBob = commitmentFor("bob's answer", saltB, bob.account.address, bountyId);
    await bountyJudge.write.submitCommitment([bountyId, commitmentAlice], { account: alice.account.address });
    await bountyJudge.write.submitCommitment([bountyId, commitmentBob], { account: bob.account.address });

    await networkHelpers.time.increaseTo(submissionDeadline + 1n);
    await bountyJudge.write.revealAnswer([bountyId, "alice's answer", saltA], { account: alice.account.address });
    // bob never reveals

    const [, revealed, answer] = await bountyJudge.read.getSubmission([bountyId, bob.account.address]);
    assert.equal(revealed, false);
    assert.equal(answer, "");
  });

  it("only lets the bounty owner call judgeAll, and only after the reveal deadline", async function () {
    const { bountyId, submissionDeadline, revealDeadline } = await createBounty();
    const commitment = commitmentFor("alice's answer", saltA, alice.account.address, bountyId);
    await bountyJudge.write.submitCommitment([bountyId, commitment], { account: alice.account.address });
    await networkHelpers.time.increaseTo(submissionDeadline + 1n);
    await bountyJudge.write.revealAnswer([bountyId, "alice's answer", saltA], { account: alice.account.address });

    await bountyJudge.write.setStubJudgingResult([0n, stringToHex('{"winnerIndex":0}')]);

    await viem.assertions.revertWithCustomError(
      bountyJudge.write.judgeAll([bountyId, "0x"], { account: alice.account.address }),
      bountyJudge,
      "NotBountyOwner"
    );

    await viem.assertions.revertWithCustomError(
      bountyJudge.write.judgeAll([bountyId, "0x"], { account: owner.account.address }),
      bountyJudge,
      "RevealPhaseNotOver"
    );

    await networkHelpers.time.increaseTo(revealDeadline + 1n);
    await viem.assertions.emit(
      bountyJudge.write.judgeAll([bountyId, "0x"], { account: owner.account.address }),
      bountyJudge,
      "BountyJudged"
    );
  });

  it("rejects a judging result pointing at an unrevealed submission", async function () {
    const { bountyId, submissionDeadline, revealDeadline } = await createBounty();
    const commitmentAlice = commitmentFor("alice's answer", saltA, alice.account.address, bountyId);
    const commitmentBob = commitmentFor("bob's answer", saltB, bob.account.address, bountyId);
    await bountyJudge.write.submitCommitment([bountyId, commitmentAlice], { account: alice.account.address });
    await bountyJudge.write.submitCommitment([bountyId, commitmentBob], { account: bob.account.address });

    await networkHelpers.time.increaseTo(submissionDeadline + 1n);
    await bountyJudge.write.revealAnswer([bountyId, "alice's answer", saltA], { account: alice.account.address });
    // bob (index 1) never reveals

    await networkHelpers.time.increaseTo(revealDeadline + 1n);
    await bountyJudge.write.setStubJudgingResult([1n, stringToHex('{"winnerIndex":1}')]); // points at bob, unrevealed

    await viem.assertions.revertWithCustomError(
      bountyJudge.write.judgeAll([bountyId, "0x"], { account: owner.account.address }),
      bountyJudge,
      "WinnerNotRevealed"
    );
  });

  it("pays the correct winner end-to-end and blocks double finalization", async function () {
    const { bountyId, submissionDeadline, revealDeadline } = await createBounty();
    const commitmentAlice = commitmentFor("alice's answer", saltA, alice.account.address, bountyId);
    const commitmentBob = commitmentFor("bob's answer", saltB, bob.account.address, bountyId);
    await bountyJudge.write.submitCommitment([bountyId, commitmentAlice], { account: alice.account.address });
    await bountyJudge.write.submitCommitment([bountyId, commitmentBob], { account: bob.account.address });

    await networkHelpers.time.increaseTo(submissionDeadline + 1n);
    await bountyJudge.write.revealAnswer([bountyId, "alice's answer", saltA], { account: alice.account.address });
    await bountyJudge.write.revealAnswer([bountyId, "bob's answer", saltB], { account: bob.account.address });

    await networkHelpers.time.increaseTo(revealDeadline + 1n);
    await bountyJudge.write.setStubJudgingResult([1n, stringToHex('{"winnerIndex":1,"summary":"bob wins"}')]);
    await bountyJudge.write.judgeAll([bountyId, "0x"], { account: owner.account.address });

    const balBefore = await publicClient.getBalance({ address: bob.account.address });
    await bountyJudge.write.finalizeWinner([bountyId, 1n], { account: owner.account.address });
    const balAfter = await publicClient.getBalance({ address: bob.account.address });
    assert.equal(balAfter - balBefore, parseEther("1"));

    await viem.assertions.revertWithCustomError(
      bountyJudge.write.finalizeWinner([bountyId, 1n], { account: owner.account.address }),
      bountyJudge,
      "AlreadyFinalized"
    );
  });

  it("rejects finalizeWinner before judging has completed", async function () {
    const { bountyId, submissionDeadline, revealDeadline } = await createBounty();
    const commitment = commitmentFor("alice's answer", saltA, alice.account.address, bountyId);
    await bountyJudge.write.submitCommitment([bountyId, commitment], { account: alice.account.address });
    await networkHelpers.time.increaseTo(submissionDeadline + 1n);
    await bountyJudge.write.revealAnswer([bountyId, "alice's answer", saltA], { account: alice.account.address });
    await networkHelpers.time.increaseTo(revealDeadline + 1n);

    await viem.assertions.revertWithCustomError(
      bountyJudge.write.finalizeWinner([bountyId, 0n], { account: owner.account.address }),
      bountyJudge,
      "NotJudgedYet"
    );
  });
});

