#!/usr/bin/env bash
set -euo pipefail

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
    echo "repo=$repo ref=${ref:-<default>}"

    # Example workflow:
    # git clone "git_path/${repo}.git"
    # cd "$repo"
    # git checkout "${ref:-master}" || git checkout master
    # cd ..
  done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$manifest_path")
}

pull_components "$1"
