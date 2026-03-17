# Summary

This project uses beads
Use 'bd' for task tracking

## Bead Lifecycle Discipline (Mandatory)

All bead work must follow these lifecycle rules:

- Always branch from `origin/main`.
- Always use git worktrees.
- Never commit `.beads/*`.
- Never commit compiled artifacts/binaries.
- Conventional commits only. No emojis.
- Bead MUST be closed when complete.
- Respect repo boundaries and existing AGENTS instructions.

## Repository Hygiene

### Worktree Discipline (Required for All Beads)
All bead work MUST run in dedicated git worktrees to ensure clean separation and prevent accidental main branch mutations.
Create worktrees inside this repository at `.worktrees/<bead-id>` (ensure `.worktrees/` exists; it is gitignored). Do not create worktrees outside the repo (for example `../wt-*`).

**Preflight (common failure checks):**
- First diagnostic: `git worktree list`
- If `.worktrees/<bead-id>` exists and appears in `git worktree list`, remove it from a different worktree with `git worktree remove .worktrees/<bead-id>`.
- If `.worktrees/<bead-id>` exists but does **not** appear in `git worktree list`, run `git worktree prune`, then re-run `git worktree list` to confirm it is still absent. If confirmed, carefully double-check the path and remove only that directory: `rm -rf .worktrees/<bead-id>`.
- If `bead/<bead-id>` already exists or is attached to another worktree, reuse that worktree or detach/remove it before creating a new one.

**Canonical Workflow:**

1. **Create worktree** before starting any bead work:
   ```bash
   git fetch origin
   git checkout main
   git pull --ff-only
   mkdir -p .worktrees
   git worktree add -b bead/<bead-id> .worktrees/<bead-id> origin/main
   cd .worktrees/<bead-id>
   ```

   If `bead/<bead-id>` already exists and should be reused:
   ```bash
   git worktree add .worktrees/<bead-id> bead/<bead-id>
   cd .worktrees/<bead-id>
   ```

2. **Run bead work** in the worktree directory.

3. **Cleanup** when done (run from the primary worktree at repo root, not inside `.worktrees/<bead-id>`):
   ```bash
   cd <repo-root>  # primary worktree
   git worktree remove .worktrees/<bead-id>
   git branch -d bead/<bead-id>
   ```

   If `git worktree remove` refuses due to uncommitted changes in that worktree, go to the target worktree and commit or stash first, then retry. Avoid `--force` unless you explicitly accept losing local changes.

   `git branch -d bead/<bead-id>` fails if the branch is not merged. In that case, skip branch deletion until after merge. Use `git branch -D bead/<bead-id>` only if you intentionally want to discard unmerged branch history.

   A common failure mode: branch deletion can also fail if `bead/<bead-id>` is still checked out in another worktree. Run `git worktree list` to find that worktree, then remove it (`git worktree remove <path>`) or detach/switch that worktree to a different branch before retrying deletion.

### Branch Safety Rules

1. **All beads must branch from latest main**
   - Run `git fetch origin && git checkout main && git pull --ff-only` before creating branch
   - Never work directly on main branch

2. **bead-sync exemption requires ALLOW_MAIN_CHECKOUT=1**
   - Only use for: syncing bead state files, running `bd sync` commands, reading from main branch
   - Always verify you're in the correct context before proceeding

3. **Agents must stop immediately if validation fails**
   - Do not proceed with implementation if worktree validation fails
   - Fix the underlying issue before continuing

### Pre-commit Checklist

Before every commit, verify:

- [ ] **No forbidden artifacts staged**: Check `git status` for `.beads/*`, `.build/`, `.swiftpm/`, `DerivedData/`, `*.xcworkspace/`, `.DS_Store`
- [ ] **Tests pass**: Run `swift test`
- [ ] **Build succeeds**: Run `swift build`
- [ ] **Changes are incremental and testable**
- [ ] **No debug statements**: No `print()`, `debugPrint()`, or logging statements left behind
- [ ] **No emojis in code/comments**: Use text only
- [ ] **Branch is descendant of origin/main**: Verify with `git log --oneline origin/main..HEAD`

### Git Ignore Conventions

The following are automatically ignored:
- `.DS_Store`
- `.vscode/`
- `.swiftpm/`
- `.build/`
- `Packages/`
- `xcuserdata/`
- `*.xcodeproj/`
- `*.xcworkspace/`
- `peer/` (runtime data)

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

## Merge Discipline (Mandatory)

Only the Orchestrator agent may request changes be MERGED.
MERGE must only occur AFTER a review of the changes has been performed by the review agent.
MERGE should be the last step performed after the associated bead has been closed.
Performing a MERGE BEFORE all steps and tasks assigned are complete is NOT allowed.
