#!/usr/bin/env bash
set -euo pipefail

DEFAULT_BRANCH="${DEFAULT_BRANCH:-master}"
GIT_BASE_URL="${GIT_BASE_URL:-}"
DRY_RUN=false
MANIFEST_PATH=""
CONTINUE_ON_ERROR=false
TOTAL_REPOS=0
SUCCESS_REPOS=0
FAILED_REPOS=0
FAILED_LIST=""

fail() {
  local repo=$1
  local step=$2
  local details=${3:-}
  echo "Error: repo='${repo}' step='${step}' failed. ${details}" >&2
  if [[ "$CONTINUE_ON_ERROR" == "true" ]]; then
    return 1
  fi
  exit 1
}

run_step() {
  local repo=$1
  local step=$2
  shift 2
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[$repo] dry-run step='${step}': $*"
    return 0
  fi
  if ! "$@"; then
    fail "$repo" "$step"
    return 1
  fi
  return 0
}

print_help() {
  cat <<'EOF'
Usage:
  pull.sh --manifest <path> [--base-url <git-base-url>] [--default-branch <branch>] [--dry-run] [--continue-on-error]
  pull.sh <manifest-path>

Options:
  --manifest <path>         Path to JSON manifest file.
  --base-url <git-base-url> Base git URL, for example: git@github.com:your-org
  --default-branch <name>   Fallback branch when origin/HEAD is unavailable (default: master).
  --dry-run                 Print actions without running git commands.
  --continue-on-error       Continue processing other repos and print summary at the end.
  -h, --help                Show this help message.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --manifest)
        [[ $# -lt 2 ]] && fail "cli" "parse-args" "Missing value for --manifest"
        MANIFEST_PATH=$2
        shift 2
        ;;
      --base-url)
        [[ $# -lt 2 ]] && fail "cli" "parse-args" "Missing value for --base-url"
        GIT_BASE_URL=$2
        shift 2
        ;;
      --default-branch)
        [[ $# -lt 2 ]] && fail "cli" "parse-args" "Missing value for --default-branch"
        DEFAULT_BRANCH=$2
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --continue-on-error)
        CONTINUE_ON_ERROR=true
        shift
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      --*)
        fail "cli" "parse-args" "Unknown option: $1"
        ;;
      *)
        if [[ -z "$MANIFEST_PATH" ]]; then
          MANIFEST_PATH=$1
          shift
        else
          fail "cli" "parse-args" "Unexpected positional argument: $1"
        fi
        ;;
    esac
  done
}

record_failure() {
  local repo=$1
  local step=$2
  FAILED_REPOS=$((FAILED_REPOS + 1))
  FAILED_LIST+="${repo}:${step}"$'\n'
}

print_summary() {
  echo "----- Summary -----"
  echo "total=${TOTAL_REPOS} success=${SUCCESS_REPOS} failed=${FAILED_REPOS}"
  if [[ $FAILED_REPOS -gt 0 ]]; then
    echo "Failed repos:"
    printf "%s" "$FAILED_LIST"
  fi
}

sync_repo() {
  local repo=$1
  local ref=$2
  local target_ref=$ref
  local remote_head_ref=""

  if [[ -d "$repo/.git" ]]; then
    echo "[$repo] existing repository found, fetching updates"
    run_step "$repo" "fetch" git -C "$repo" fetch --all --prune
  else
    if [[ -z "$GIT_BASE_URL" ]]; then
      fail "$repo" "clone" "Set GIT_BASE_URL, for example: export GIT_BASE_URL=git@github.com:your-org"
      return 1
    fi

    echo "[$repo] cloning from ${GIT_BASE_URL}/${repo}.git"
    run_step "$repo" "clone" git clone "${GIT_BASE_URL}/${repo}.git" "$repo"
  fi

  if [[ -n "$target_ref" ]]; then
    echo "[$repo] checking out explicit ref '${target_ref}'"
    run_step "$repo" "checkout" git -C "$repo" checkout "$target_ref"
    return 0
  fi

  remote_head_ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  remote_head_ref=${remote_head_ref#origin/}

  if [[ -n "$remote_head_ref" ]]; then
    echo "[$repo] checking out detected default branch '${remote_head_ref}' from origin/HEAD"
    if git -C "$repo" checkout "$remote_head_ref"; then
      return 0
    fi
    echo "[$repo] warning: checkout of origin/HEAD target '${remote_head_ref}' failed, falling back" >&2
  else
    echo "[$repo] warning: origin/HEAD is not available, falling back to DEFAULT_BRANCH='${DEFAULT_BRANCH}'" >&2
  fi

  echo "[$repo] checking out fallback DEFAULT_BRANCH '${DEFAULT_BRANCH}'"
  run_step "$repo" "checkout-default-branch" git -C "$repo" checkout "$DEFAULT_BRANCH"
}

pull_components() {
  local manifest_path=${1:-}
  local repo
  local ref

  if [[ -z "$manifest_path" ]]; then
    echo "Usage: $0 <components.json>" >&2
    return 2
  fi

  if [[ ! -f "$manifest_path" ]]; then
    echo "Error: manifest file not found: $manifest_path" >&2
    return 2
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required to parse JSON manifest" >&2
    return 2
  fi

  while IFS=$'\t' read -r repo ref; do
    if [[ -z "$repo" ]]; then
      continue
    fi

    TOTAL_REPOS=$((TOTAL_REPOS + 1))
    echo "repo=$repo ref=${ref:-$DEFAULT_BRANCH}"
    if sync_repo "$repo" "$ref"; then
      SUCCESS_REPOS=$((SUCCESS_REPOS + 1))
    else
      record_failure "$repo" "sync"
      if [[ "$CONTINUE_ON_ERROR" != "true" ]]; then
        exit 1
      fi
      echo "[$repo] continue-on-error enabled, moving to next repository" >&2
    fi
  done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$manifest_path")

  print_summary
  if [[ $FAILED_REPOS -gt 0 ]]; then
    exit 1
  fi
}

parse_args "$@"
pull_components "$MANIFEST_PATH"
