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

# Aethos: Agent Operating Rules

## Non-negotiable
- Use `bd` for all task tracking. Do not use ad-hoc TODO markdown.
- On session start: run `bd prime` and `bd ready`.
- Before ending session: run `bd sync`.

## MVP0 Scope
- Protocol + core model + identity + crypto + chunking + store.
- No Zephyrs (relays) in MVP0.
- No BLE transport in MVP0 (comes after core is stable).

## Architecture Style
- Bead-style decomposition: each module owns its state; communicate via explicit interfaces.
- Do not change protocol IDs/encoding rules without filing a bd issue tagged `protocol-change`.

