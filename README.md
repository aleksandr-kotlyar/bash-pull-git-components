## bash-pull-git-components

Sync multiple git repositories from a single JSON manifest.

The script can:
- clone repositories that do not exist locally
- fetch updates for existing repositories
- checkout explicit `ref` from the manifest (branch/tag/commit)
- fallback for empty `ref` using `origin/HEAD -> DEFAULT_BRANCH`

## Manifest format

`components.json` is a JSON object where:
- key = repository name
- value = target git ref (branch/tag/commit)
- empty string value means "use fallback checkout logic"

Example:

```json
{
  "one": "",
  "two": "release/2026.04",
  "three": "a1b2c3d4"
}
```

## Usage

```bash
./pull.sh --manifest <path-to-components.json> [--base-url <git-base-url>] [--default-branch <branch>] [--dry-run]
```

Flags:
- `--manifest <path>`: path to JSON manifest file (required unless positional path is used)
- `--base-url <url>`: base git URL, for example `git@github.com:your-org`
- `--default-branch <name>`: fallback branch when `origin/HEAD` is unavailable (default: `master`)
- `--dry-run`: print planned actions without running git commands
- `-h`, `--help`: show help

Backward-compatible positional usage is still supported:

```bash
./pull.sh ./examples/components.json
```

## Checkout fallback behavior

For each repository:
1. If manifest value is non-empty, script runs `git checkout <ref>`.
2. If manifest value is empty, script tries default branch from `origin/HEAD`.
3. If step 2 is unavailable or fails, script falls back to `--default-branch`.

This removes hard dependency on `master`/`main` naming in your repositories.

## Local examples

Dry run:

```bash
./pull.sh --manifest ./examples/components.json --base-url git@github.com:your-org --default-branch main --dry-run
```

Real run:

```bash
./pull.sh --manifest ./examples/components.json --base-url git@github.com:your-org --default-branch main
```

## CI example (GitHub Actions)

```yaml
name: Sync Components
on: [workflow_dispatch]

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install jq
        run: sudo apt-get update && sudo apt-get install -y jq
      - name: Sync repos
        run: |
          chmod +x ./pull.sh
          ./pull.sh \
            --manifest ./examples/components.json \
            --base-url git@github.com:your-org \
            --default-branch main
```

## Common errors and exit codes

- Exit code `0`: success.
- Exit code `1`: git operation failure (`clone`, `fetch`, `checkout`) or runtime sync failure for a repo.
- Exit code `2`: CLI/input validation error, for example:
  - missing `--manifest` value
  - unknown CLI option
  - manifest file does not exist
  - `jq` is not installed
  - `--base-url` is required when repository must be cloned
