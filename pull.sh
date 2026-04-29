#!/usr/bin/env bash
set -euo pipefail

DEFAULT_BRANCH="${DEFAULT_BRANCH:-master}"
GIT_BASE_URL="${GIT_BASE_URL:-}"

fail() {
  local repo=$1
  local step=$2
  local details=${3:-}
  echo "Error: repo='${repo}' step='${step}' failed. ${details}" >&2
  exit 1
}

run_step() {
  local repo=$1
  local step=$2
  shift 2
  if ! "$@"; then
    fail "$repo" "$step"
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

    echo "repo=$repo ref=${ref:-$DEFAULT_BRANCH}"
    sync_repo "$repo" "$ref"
  done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$manifest_path")
}

pull_components "$1"
