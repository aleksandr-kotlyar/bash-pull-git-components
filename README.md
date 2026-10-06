# bash-pull-git-components

Clone and update a set of independent Git repositories from one JSON manifest.
Requires Bash 3.2+, Git, and jq. Repository paths are relative to the **current
working directory**; the manifest can be stored elsewhere.

```json
{
  "backend": "main",
  "frontend": "release/1.2",
  "library": "v2.0",
  "tools": ""
}
```

Keys are relative repository paths, including `group/repo`; components may contain
letters, digits, `_`, `-`, and `.`. Absolute paths, `.`/`..`/`.git` components,
leading hyphens, and overlapping paths such as `app` and `app/plugin` are rejected.
Values are branch names, tags, commit IDs (at least seven hex digits), or `""`.
The entire manifest is validated before Git operations. An empty object is valid.

## Usage

```bash
./pull.sh --manifest components.json --base-url git@github.com:your-org
./pull.sh components.json --jobs 4
./pull.sh components.json --fetch
./pull.sh components.json --force
```

| Option | Behavior |
| --- | --- |
| `--manifest PATH` | JSON manifest; a positional path also works. |
| `--base-url URL` | Clone prefix, or set `GIT_BASE_URL`. Needed only for missing repositories. |
| `--default-branch REF` | Fallback branch, or set `DEFAULT_BRANCH`; default `master`. |
| `--fetch` | Fetch **origin only**, leaving the current branch, index, and working files alone. Missing repositories fail; this mode does not clone. |
| `--force` | Match the selected remote branch exactly, confirming local losses per repository. Requires `--jobs 1`; incompatible with `--fetch`. |
| `--jobs N` | Process up to N repositories in parallel (1–9999); default 1. |
| `--help` | Show help. |

`--dry-run` and `--continue-on-error` have been removed. Processing always continues
after a repository failure, and all failures are reported at the end.

## Updating a repository

1. Clone a missing repository from `<base-url>/<path>.git`, or fetch `origin --prune`.
2. Resolve the requested ref. An origin branch takes precedence over a same-named
   tag; tags and commit IDs are checked out with detached HEAD.
3. For a branch, switch to its local branch and merge the fetched commit with
   `--ff-only`. No merge commits or rebases are created. Local commits ahead of
   origin remain in normal mode; divergent history is a failure.

For `""`, query the current default branch on origin. If it cannot be determined
(including a failed HEAD query), use `DEFAULT_BRANCH` and print a warning. A failed
fetch or checkout remains an error; a checkout failure never silently selects the
fallback branch. Explicit missing refs also fail.

Only origin is fetched, regardless of other remotes or branch upstream settings.
Existing repositories, including linked worktrees, must be rooted at their manifest
path. Complete or abort an ongoing merge/rebase/cherry-pick/revert before updating.
Submodule trees and index flags that hide changes (`assume-unchanged` or
`skip-worktree`, including sparse checkouts) are not supported by update/force mode.
They fail clearly instead of risking an incomplete loss preview; fetch-only works.

## Force and local files

Normal mode refuses uncommitted tracked changes and untracked files obstructing
the selected version. This includes ignored files; unrelated untracked files stay.

`--force` uses ordinary fast-forward updates when possible. Before a destructive
update it lists the affected repository, target commit, local commits removed from
the selected branch, uncommitted tracked changes, and obstructing untracked/ignored
files or directories. Directory entries include their contents. Only an explicit
`y` or `yes` confirms the overwrite. Any other answer declines it.

After confirmation, the selected local branch and tracked files match the fetched
origin commit. Tags/commit IDs remain detached. Only obstructing untracked files
are overwritten; there is no blanket `git clean`, automatic stash, or merge-conflict
resolution. Refusing confirmation leaves local work alone (fetch has already run).

## Failures and exclusions

After the first pass, show all failed repositories with reasons. At a terminal,
each failure offers:

- **retry** (`r`): repeat this repository with the same options, sequentially;
- **skip** (`s`, Enter, or end of input): leave it failed for this run;
- **ignore for future** (`i`): append its path to `<manifest>.ignore`, one per line.
  The manifest is unchanged. The failure still counts in the current run.

Every run displays a nonempty exclusions file and recommends fixing the repositories
and removing their exclusions, or removing unused repositories from the manifest.
Blank lines and lines starting with `#` are ignored. Remove stale exclusions as well. To restore a repository, delete its exclusion line.
Excluded repositories are counted separately and are not attempted.

Without terminal input, perform all updates that need no confirmation, print the
report, and exit. There are no questions, automatic confirmations, or automatic
retries. A successful retry clears its failure; an unresolved failure stays visible.

## Parallel execution and debugging

`--jobs N` uses bounded batches of up to N repositories. This keeps the scheduler
small; a slow repository can delay the next batch. Each job's Git output is buffered
and printed together, without interleaving. Single mode prints Git output live.
Use noninteractive Git/SSH credentials for parallel or unattended runs.

After parallel work, failure review and retries run sequentially. `--force --jobs N`
with N greater than one is rejected before any Git operation. Ctrl+C/termination
stops active parallel process groups, including their Git/SSH children.

Exit codes: **0** — no unresolved failures (pre-existing exclusions are separate);
**1** — at least one repository failed or was skipped/ignored after failure;
**2** — invalid arguments, manifest, or setup. Interrupt/termination returns 130/143.
Git diagnostics are printed along with the repository and operation that failed.

## Checks

```bash
bash tests/run-tests.sh
shellcheck pull.sh tests/run-tests.sh
```

Tests need Python 3's standard library, Git, and jq; no Bats or Python packages.
They create temporary local remotes and exercise real Git state changes, terminal
confirmations, failure recovery, exclusions, and parallel execution. No network or
user repositories are used. Set `TEST_BASH=/path/to/bash` to test another Bash.
