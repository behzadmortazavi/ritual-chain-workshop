# Architecture Note

## 1. Commit-reveal vs. Ritual-native encrypted submissions

| | Commit-reveal (required track) | Ritual-native encrypted (advanced track) |
|---|---|---|
| What's public during submission | A hash only — zero information about the content | Ciphertext only (or just a pointer/hash if stored off-chain) |
| When plaintext appears | The moment each participant reveals — **before** judging, visible to anyone watching the chain | Only inside the TEE at judging time; public reveal happens **after** judging, all at once |
| Copy risk window | Between reveal and judgeAll, a participant's answer is public and could theoretically still be reused for a *future* bounty | None — no one, including the bounty owner, ever sees plaintext before judging |
| Trust assumption | None beyond the EVM — pure hash commitment | Trusts the TEE (Ritual's attested execution environment, accessed via the `LLM_INFERENCE_PRECOMPILE` at `0x0802`) to actually keep secrets during execution |
| Gas / complexity | Simple, cheap, works on any EVM chain | Needs Ritual's encrypted-input/TEE infrastructure; more moving parts |
| Failure mode if someone forgets to reveal | Submission is silently excluded | Same — no reveal, no ciphertext delivered to judging, excluded |

The core weakness commit-reveal *doesn't* fully solve: participants still
reveal individually and publicly before the AI ever looks at anything, so
technically a very fast, very late revealer could watch everyone else's
reveal transactions land in the mempool/get mined and adjust their own
reveal in the last block before the reveal deadline (they can't change the
*content* of what they already committed to, but they *can* choose whether
to reveal at all based on what they've seen — a soft form of information
leakage). Ritual-native hidden submissions close this gap by never
revealing anything to any human until judging is already finished.

## 2. Advanced track design (Ritual-native hidden submissions)

### Where plaintext exists, and who can read it
Plaintext answers exist in exactly two places: (a) briefly on the
participant's own device while they encrypt it, and (b) inside Ritual's TEE
during the `judgeAll` execution, where the LLM reads it to score it. No
other party — not other participants, not the bounty owner, not a chain
indexer — ever has access to plaintext before judging completes.

### What's on-chain vs. off-chain
On-chain: a commitment to the encrypted submission (its hash or a short
reference), the bounty metadata (deadlines, reward), and — after judging —
`revealedAnswersRef` + `revealedAnswersHash` pointing at the final bundle.
Off-chain: the actual ciphertext blobs (stored e.g. via IPFS or Ritual's own
storage), and the plaintext revealed-answers bundle published post-judging.
Keeping large ciphertext/plaintext blobs off-chain avoids paying calldata/
storage gas for content that doesn't need to be queried by the contract
itself — the contract only needs to verify a hash, not the content.

### How the LLM receives all submissions together
Off-chain tooling (or an indexer watching submission events) collects every
participant's encrypted reference for a bounty and assembles a single batch
job. `judgeAll` calls `LLM_INFERENCE_PRECOMPILE` (`0x0802`) exactly once,
synchronously, in the same transaction — the TEE decrypts all submissions
*inside* the trusted environment and hands the LLM one prompt containing
every answer plus the judging rubric. This is the same pattern the
required-track contract already uses (`BountyJudge._judgeSubmissions`), just
extended so the encrypted references get decrypted inside the TEE rather
than the plaintext already sitting in calldata.

### How the final reveal happens
Once judging finishes, the TEE workflow (or the owner, using output from it)
publishes a `revealedAnswersBundle` (all plaintext answers + which one won)
to off-chain storage, and the contract stores only `revealedAnswersHash =
keccak256(bundle)` plus a pointer (`revealedAnswersRef`). Anyone can fetch
the bundle and verify it against the on-chain hash — they don't have to
trust whoever hosts the storage reference.

### How the contract verifies/commits to the bundle
The contract never trusts the bundle's *content* directly — it only stores
the hash. Verification is symmetric to commit-reveal: fetch the bundle,
hash it, compare to `revealedAnswersHash`. If the TEE result also gets
attested (a signature/proof that the specific TEE code ran on the specific
inputs), the contract can additionally check that attestation before
recording `winnerIndex`, so a compromised off-chain relayer can't just
invent a winner.

### Example output shape (from the homework)
```json
{
  "winnerIndex": 2,
  "ranking": [{ "index": 2, "score": 94, "reason": "Best satisfies the rubric." }],
  "revealedAnswersRef": "ipfs://... or storage-ref://...",
  "revealedAnswersHash": "0x...",
  "summary": "Submission 2 is the strongest answer."
}
```
This maps directly onto `judgeAll`/`_judgeSubmissions` in `BountyJudge.sol`:
the LLM's raw JSON output already flows through as `rawOutput` and gets
hashed into `judgingOutputHash`; `revealedAnswersRef` would just be one more
field set alongside it (e.g. parsed via a second `JQ_PRECOMPILE` call or by
an off-chain indexer reading the `BountyJudged` event's `judgingOutput`
bytes). So the required-track contract is a small extension away from
supporting this advanced flow rather than a rewrite.

## 3. Reflection question

*What should be public, what should stay hidden, and what should be decided
by AI versus by a human in a bounty system?*

The existence of a bounty, its reward, and its deadlines should always be
public — participants need that to decide whether to enter at all. The
content of an answer should stay hidden for the entire submission window,
because the whole point of the bounty is that everyone is solving the
problem independently; leaking answers early turns it into a race to copy
the best idea rather than a fair contest. Commitments (hashes) can be
public immediately since they reveal nothing about content but still prove,
later, that someone didn't change their answer after the fact. After
judging is complete, answers should become fully public again, both for
transparency (so participants can check the AI judged fairly) and so the
broader community benefits from the ideas that were submitted. On the
decision side, AI is well suited to the mechanical parts of judging —
reading every submission against a rubric and producing a consistent,
tireless ranking, especially at a scale where a human reading every entry
isn't practical. But a human should always make the final call on whether
to pay out, because AI scoring can be wrong, gamed, or applied to a rubric
that didn't anticipate an edge case, and money changing hands should have a
person accountable for the decision, not just a model's output.

