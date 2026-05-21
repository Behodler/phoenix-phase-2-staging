Update a git submodule to its latest remote commit and commit the pointer bump at the repo root
# Purpose
Keep `lib/` submodules aligned with upstream by fetching the latest commit on the tracked branch, moving the submodule pointer, and recording the change in a root-level commit using the project's standard message format:

```
Update <submodule-dirname> to latest (<short-sha>)
```

This project (`phase-2-staging`) is a Phase 2 deployment orchestration layer. Its `lib/` directory contains the contract submodules that get deployed (`phlimbo-ea`, `phUSD-stable-minter`, `yield-claim-nft`, `vault`, `flax-token-v2`, `pauser`, `nft-staking`, `stable-yield-accumulator`) plus tooling (`forge-std`). When upstream contract repos publish fixes, this command pulls them in for re-deployment.

# Arguments
- `$ARGUMENTS` format: `[name]` (optional)
- `name` is a submodule directory under `lib/` (e.g., `yield-claim-nft`, `phlimbo-ea`, `phUSD-stable-minter`)
- If omitted, prompt the user to either:
  1. pick a specific submodule, or
  2. update all submodules under `lib/`

# Orchestration Flow

## 1. Parse Arguments
- If `$ARGUMENTS` is non-empty: treat it as the target name and proceed to step 2
- If `$ARGUMENTS` is empty:
  - List the directory entries under `lib/` from `.gitmodules`
  - Ask the user: "Update all submodules, or name a specific one?" via `AskUserQuestion`
  - Wait for the user's choice before proceeding
  - **Skip `forge-std`** when updating "all" — it is a testing dependency, not contract code, and gets bumped through `forge install`

## 2. Update Flow (single submodule)
For target submodule `lib/<dirname>`:

1. Validate `lib/<dirname>` exists and is listed in `.gitmodules`
2. Record the current (old) short SHA: `git -C lib/<dirname> rev-parse --short HEAD`
3. Determine the tracked branch, in order of preference:
   1. The `branch` key in `.gitmodules` for this submodule, if any
   2. The submodule's remote HEAD (`git -C lib/<dirname> remote show origin | awk '/HEAD branch/ {print $NF}'`)
4. Confirm the submodule working tree is clean: `git -C lib/<dirname> status --porcelain`
   - If dirty, abort and report — do not stash or discard
5. Fetch and fast-forward (NEVER use `--recursive`):
   1. `git -C lib/<dirname> fetch origin`
   2. `git -C lib/<dirname> checkout <branch>`
   3. `git -C lib/<dirname> pull --ff-only origin <branch>`
6. Capture the new short SHA: `git -C lib/<dirname> rev-parse --short HEAD`
7. If old == new: report "already up to date" and do NOT create a commit
8. Otherwise:
   1. Stage ONLY the pointer move at root: `git add lib/<dirname>`
   2. Verify the staged diff only touches `lib/<dirname>` (no unrelated files) — `git diff --cached --name-only`
   3. Commit at repo root with message exactly: `Update <dirname> to latest (<new-short-sha>)`
   4. Do NOT use `--no-verify` or bypass hooks

## 3. Update Flow (all submodules)
- Enumerate submodules from `.gitmodules`, excluding `lib/forge-std`
- For each submodule, perform the steps from section 2
- Create one commit per submodule that actually moved (do not squash)
- Continue through the list even if an individual submodule fails; collect errors and report at the end

## 4. Completion Report
Present to user:
- For each submodule processed: `<dirname>`, `<old-sha>` → `<new-sha>`, or `already up to date`, or `error: <reason>`
- The list of commit SHAs created at the repo root
- Any skipped submodules and the reason
- A reminder when contract submodules moved: "Re-deploy may be required — rerun `npm run deploy:<network>` against the relevant `progress.<chainId>.json`."

# Error Handling
- **Name not found**: report that `<name>` doesn't match a directory under `lib/`, and list valid choices
- **Dirty working tree inside `lib/<dirname>`**: abort that submodule and report — do not force-discard changes
- **Staged diff touches files outside `lib/<dirname>`**: abort the commit and report; the user likely has unrelated staged work (this is likely given current `git status` shows modified `package.json` and unrelated broadcast/script files)
- **Non-fast-forward upstream**: report the divergence and stop; do not attempt rebase or force
- **Detached HEAD with no tracked branch discoverable**: report and skip
- **SSH auth failure** on the `git@github.com:Behodler/...` submodules: report and skip — the user needs to ensure their SSH agent is loaded

# Critical Rules
1. **NEVER use `--recursive`** when fetching/updating submodules — phStaging2's submodules each have their own nested deps and recursive fetches cause noise
2. **NEVER modify files inside `lib/<dirname>`** — only move the submodule pointer from the outer repo. Contract code lives in upstream repos (see CLAUDE.md: "Never commit changes inside lib/ directories")
3. **Commit only the pointer change** — stage `lib/<dirname>` by path, never `git add -A`. The repo currently has unrelated dirty files (`package.json`, new broadcast/script files) that must not be swept into the pointer-bump commit
4. **Never bypass hooks** (`--no-verify`, `--no-gpg-sign`) unless the user explicitly asks
5. One commit per submodule that moved; do not squash multi-submodule updates into a single commit
6. **Skip `lib/forge-std`** on "all" runs — it's a Foundry dependency, not project contract code

# Examples
```
/update-lib yield-claim-nft
# Fetches lib/yield-claim-nft to latest on its tracked branch
# Commits at root: "Update yield-claim-nft to latest (<new-short-sha>)"

/update-lib phlimbo-ea
# Commits: "Update phlimbo-ea to latest (<new-short-sha>)"

/update-lib phUSD-stable-minter
# Commits: "Update phUSD-stable-minter to latest (<new-short-sha>)"

/update-lib
# Lists submodules and asks: "Update all, or name one?"
# Then proceeds accordingly
```
