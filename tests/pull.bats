#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$REPO_ROOT/pull.sh"
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "fails when manifest is missing" {
  run "$SCRIPT" --manifest "$TMPDIR_TEST/not-found.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"manifest file not found"* ]]
}

@test "fails on unknown option" {
  run "$SCRIPT" --unknown-flag
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "fails when --jobs is not a number" {
  run "$SCRIPT" --manifest "$TMPDIR_TEST/manifest.json" --jobs abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"--jobs must be a positive integer"* ]]
}

@test "dry-run parses manifest and prints summary" {
  cat > "$TMPDIR_TEST/manifest.json" <<'JSON'
{
  "one": "",
  "two": "feature/x"
}
JSON

  run "$SCRIPT" --manifest "$TMPDIR_TEST/manifest.json" --base-url git@github.com:example-org --default-branch main --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo=one ref=main"* ]]
  [[ "$output" == *"repo=two ref=feature/x"* ]]
  [[ "$output" == *"----- Summary -----"* ]]
  [[ "$output" == *"total=2 success=2 failed=0"* ]]
}

@test "continue-on-error processes all repos and exits 1 with summary" {
  cat > "$TMPDIR_TEST/manifest.json" <<'JSON'
{
  "one": "",
  "two": ""
}
JSON

  run "$SCRIPT" --manifest "$TMPDIR_TEST/manifest.json" --continue-on-error
  [ "$status" -eq 1 ]
  [[ "$output" == *"continue-on-error enabled"* ]]
  [[ "$output" == *"total=2 success=0 failed=2"* ]]
}
