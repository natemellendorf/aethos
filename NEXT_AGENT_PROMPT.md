# Next Agent Prompt

You are continuing work for Aethos Gossip V1 canonical author binding.

Context:
- Branch to use: bead/protocol-author-binding-v1
- Latest commit: f6a2ee68bb29
- Commit subject: feat(protocol): enforce GossipV1 author binding checks
- Scope already changed includes:
  - docs/protocol/{frames.md,gossip.md,encounter.md}
  - GossipV1 frame verification in AethosCore
  - fixture + compatibility vectors
  - new signature conformance tests

Tasks:
1) Verify branch state and inspect commit f6a2ee68bb29.
2) Run quality gates:
   - swift test
   - swift build
3) Perform strict requirement audit against this checklist:
   - Envelope requires author_pubkey + author_sig
   - Sender derived only from wayfarer_id = SHA-256(author_pubkey)
   - Signing payload exactly CanonicalCBOR({to_wayfarer_id, manifest_id, body})
   - Signature digest exactly SHA-256("AETHOS_ENVELOPE_V1" || signing_payload), signed via Ed25519
   - Fail-closed verification/rejection behavior
   - item_id from full canonical envelope bytes; different authors => different item_ids
   - Relay neutrality (no mutation/resign/wrap)
   - Transport/session identity not used for canonical sender attribution
   - Client behavior requirements enforce canonical author display and rejection of unverifiable objects
   - Docs updated across frames/gossip/encounter
   - Conformance vectors for valid sig, invalid sig, mismatched pubkey/sig, deterministic derivation, relay-forward verification
4) If any gaps remain, implement fixes and re-run tests.
5) Return:
   - PASS/FAIL matrix with file references
   - test/build outputs
   - final changed files
   - exact follow-ups (if any)

Constraints:
- Follow AGENTS.md bead/worktree rules
- Do not use transport metadata for sender attribution
- Keep spec language normative (MUST/MUST NOT) where required

Then:
1) Commit only this new file with message: `docs: add next-agent handoff prompt`
2) Push branch to origin
3) Report:
   - commit hash
   - push result
   - file path
   - `git status -sb`

Do not modify any other files.
