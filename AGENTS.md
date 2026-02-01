# Summary

This project uses beads
Use 'bd' for task tracking

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

# Aethos Agent Rules (MVP0)

## Always use Beads
- At session start: `bd prime` then `bd ready`
- Before finishing: `bd sync`
- Work must map to a bd issue. If you discover work, create a new issue.

## Scope (MVP0)
- Implement: Protocol, Identity, Crypto, Chunking, Store, Routing
- No Zephyrs (relays)
- No BLE transport yet
- iOS app UI is not part of MVP0 (core only)

## Protocol Decisions (frozen for MVP0)
- Encoding: CBOR
- Hashing: SHA-256 for IDs
- Signatures: Ed25519
- Chunk size: 32768 bytes (32KB) fixed for v1
- Envelope includes `toWayfarerId` visible in MVP0

## Boundaries
- Each bead owns its module directory only.
- No cross-module changes without opening a bd issue tagged `boundary-change`.
