#!/usr/bin/env bash
# Bash 3.2+. Every fallible step is checked explicitly; no dependence on set -e.
set -uo pipefail
export LC_ALL=C
# -C must select each repository, independent of the caller's Git environment.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

DEFAULT_BRANCH=${DEFAULT_BRANCH:-master}
GIT_BASE_URL=${GIT_BASE_URL:-}
MANIFEST="" JOBS=1 FORCE=false FETCH_ONLY=false INTERACTIVE=false
RUN_DIR="" EXCLUSIONS="" COUNT=0 ACTIVE=0
REPOS=() REFS=() RESULTS=() PIDS=() BATCH=()

usage() {
  cat <<'HELP'
Usage: pull.sh [--manifest] <components.json> [options]
  --base-url <url>        Clone URL prefix (or GIT_BASE_URL).
  --default-branch <ref>  Fallback for an unavailable origin/HEAD (default: master).
  --fetch                Fetch origin only; do not switch or update working files.
  --force                Match origin exactly after confirming any local losses.
  --jobs <N>             Parallel repositories (default: 1; incompatible with --force).
  -h, --help             Show help.

Failures are reviewed at the end: retry / skip / ignore for future.
Exclusions are stored in <components.json>.ignore and displayed on every run.
Without a terminal, no questions are asked and destructive updates are skipped.
HELP
}

fatal() { printf 'Error: %s\n' "$*" >&2; exit 2; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --manifest|--base-url|--default-branch|--jobs)
        [[ $# -ge 2 && -n $2 && $2 != --* ]] || fatal "Missing value for $1"
        case $1 in
          --manifest) [[ -z $MANIFEST ]] || fatal 'Manifest specified twice'; MANIFEST=$2 ;;
          --base-url) GIT_BASE_URL=$2 ;;
          --default-branch) DEFAULT_BRANCH=$2 ;;
          --jobs) JOBS=$2 ;;
        esac
        shift 2 ;;
      --fetch) FETCH_ONLY=true; shift ;;
      --force) FORCE=true; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) fatal "Unknown option: $1" ;;
      *) [[ -z $MANIFEST ]] || fatal "Unexpected argument: $1"; MANIFEST=$1; shift ;;
    esac
  done
  [[ $JOBS =~ ^[1-9][0-9]{0,3}$ ]] || fatal '--jobs must be an integer from 1 to 9999'
  [[ $FORCE == false || $JOBS == 1 ]] || fatal '--force requires --jobs 1'
  [[ $FORCE == false || $FETCH_ONLY == false ]] || fatal '--force and --fetch are mutually exclusive'
  [[ -f $MANIFEST ]] || fatal "Manifest file not found: $MANIFEST"
  command -v git >/dev/null || fatal 'git is required'
  command -v jq >/dev/null || fatal 'jq is required'
  git check-ref-format --branch "$DEFAULT_BRANCH" >/dev/null 2>&1 || fatal 'Invalid default branch'
}

load_manifest() {
  # Validate the entire input before cloning, fetching, or editing exclusions.
  jq -s '
    if length != 1 or (.[0] | type) != "object" then error("Expected one JSON object")
    else .[0] end |
    to_entries[] |
    if (.key | test("^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$")) and
       (.key | split("/") | all(. != "." and . != ".." and . != ".git" and (startswith("-") | not))) and
       (.value | type == "string") and (.value | test("[\\s\\\\]" ) | not)
    then empty else error("Invalid repository or ref: " + .key) end
  ' "$MANIFEST" >/dev/null || fatal 'Invalid manifest'
  jq -r 'to_entries[] | [.key, .value] | @tsv' "$MANIFEST" > "$RUN_DIR/manifest" || fatal 'Cannot read manifest'
  local repo ref other
  while IFS=$'\t' read -r repo ref; do
    [[ -z $ref ]] || git check-ref-format "refs/heads/$ref" >/dev/null 2>&1 || fatal "Invalid ref for $repo: $ref"
    # Nested entries could operate on the same working tree in parallel.
    for ((other=0; other<COUNT; other++)); do
      [[ $repo != "${REPOS[$other]}"/* && ${REPOS[$other]} != "$repo"/* ]] || fatal "Overlapping repository paths: $repo, ${REPOS[$other]}"
    done
    REPOS[COUNT]=$repo REFS[COUNT]=$ref RESULTS[COUNT]=pending
    COUNT=$((COUNT + 1))
  done < "$RUN_DIR/manifest"
  EXCLUSIONS="${MANIFEST}.ignore"
  : > "$RUN_DIR/exclusions" || fatal 'Cannot prepare exclusions'
  if [[ -e $EXCLUSIONS ]]; then
    [[ -f $EXCLUSIONS && -r $EXCLUSIONS ]] || fatal "Cannot read exclusions: $EXCLUSIONS"
    sed '/^[[:space:]]*$/d; /^#/d' "$EXCLUSIONS" > "$RUN_DIR/exclusions" || fatal 'Cannot read exclusions'
    if [[ -s $RUN_DIR/exclusions ]]; then
      printf 'Exclusions (%s):\n' "$EXCLUSIONS"
      cat "$RUN_DIR/exclusions" || fatal 'Cannot read exclusions'
      printf '\nFix excluded repos and remove their exclusions, or remove unused repos from the manifest.\nRemove stale exclusions for repos no longer in the manifest.\n'
    fi
  fi
}

stop_worker() {
  kill -TERM -- "-$1" 2>/dev/null || true
  kill -CONT -- "-$1" 2>/dev/null || true # Let stopped workers receive termination.
}

cleanup() {
  local slot pid
  for ((slot=0; slot<ACTIVE; slot++)); do
    pid=${PIDS[$slot]}
    # Parallel workers have their own process groups, including child git/ssh commands.
    stop_worker "$pid"
  done
  for ((slot=0; slot<ACTIVE; slot++)); do wait "${PIDS[$slot]}" 2>/dev/null || true; done
  [[ -z $RUN_DIR ]] || rm -rf -- "$RUN_DIR"
}

# index and repo are local to sync_repo and visible to its helper functions.
problem() {
  printf '%s\n' "$*" > "$RUN_DIR/$index.error"
  printf 'Error [%s]: %s\n' "$repo" "$*" >&2
  return 1
}

step() {
  local label=$1; shift
  printf '[%s] %s\n' "$repo" "$label"
  "$@" || { problem "$label failed"; return 1; }
}

find_blockers() {
  local prefix="$RUN_DIR/$index"
  # A temporary index describes the target tree without changing the real index.
  # Quoted Git paths make sort/comm safe even for filenames containing newlines.
  git -C "$repo" -c core.quotePath=true ls-files --others | sort > "$prefix.before" || return 1
  GIT_INDEX_FILE="$prefix.index" git -C "$repo" read-tree "$target" || return 1
  GIT_INDEX_FILE="$prefix.index" git -C "$repo" -c core.quotePath=true ls-files --others | sort > "$prefix.after" || return 1
  GIT_INDEX_FILE="$prefix.index" git -C "$repo" -c core.quotePath=true ls-files --killed | sort > "$prefix.killed" || return 1
  # Same-path overwrites, plus file/directory conflicts. Includes ignored files.
  comm -23 "$prefix.before" "$prefix.after" > "$prefix.overwrites" || return 1
  comm -12 "$prefix.before" "$prefix.killed" >> "$prefix.overwrites" || return 1
  sort -u "$prefix.overwrites" > "$prefix.blockers"
}

confirm_losses() {
  local report="$RUN_DIR/$index.losses" answer
  {
    printf '[%s] Target: %s (%s)\n' "$repo" "$ref" "$target"
    if [[ -n $commits ]]; then printf 'Local commits removed from %s:\n%s\n' "$branch" "$commits"; fi
    if [[ -n $dirty ]]; then printf 'Uncommitted tracked changes to discard:\n%s\n' "$dirty"; fi
    if [[ -s $RUN_DIR/$index.blockers ]]; then
      printf 'Untracked/ignored files or directories to overwrite (directory contents included):\n'
      cat "$RUN_DIR/$index.blockers"
    fi
  } > "$report" || return 1
  if [[ $INTERACTIVE == true ]]; then cat "$report" >&4 || return 1; else cat "$report" || return 1; fi
  [[ $FORCE == true ]] || { problem 'Local changes or untracked blockers; use --force for a confirmed overwrite'; return 1; }
  [[ $INTERACTIVE == true ]] || { problem 'Overwrite requires interactive confirmation'; return 1; }
  printf 'Discard the listed data for %s? [y/N] ' "$repo" >&4
  IFS= read -r answer <&3 || answer=""
  case $answer in y|yes) return 0 ;; *) problem 'Overwrite declined'; return 1 ;; esac
}

sync_repo() {
  local index=$1 repo=${REPOS[$1]} ref=${REFS[$1]}
  local branch="" target="" gitdir dirty="" commits="" remote_info fresh=false
  if [[ ! -e $repo ]]; then
    [[ $FETCH_ONLY == false ]] || { problem '--fetch requires an existing repository'; return 1; }
    [[ -n $GIT_BASE_URL ]] || { problem 'Cloning requires --base-url or GIT_BASE_URL'; return 1; }
    step clone git clone -- "${GIT_BASE_URL%/}/${repo}.git" "$repo" || return 1
    fresh=true
  fi
  gitdir=$(git -C "$repo" rev-parse --absolute-git-dir) || { problem 'Not a Git repository'; return 1; }
  [[ $(git -C "$repo" rev-parse --show-prefix) == "" ]] || { problem 'Path is inside another repository'; return 1; }
  if [[ $fresh == false ]]; then
    step 'fetch origin' git -C "$repo" fetch origin --prune || return 1
  fi
  [[ $FETCH_ONLY == false ]] || return 0
  if [[ -f $gitdir/MERGE_HEAD || -f $gitdir/CHERRY_PICK_HEAD || -f $gitdir/REVERT_HEAD || -d $gitdir/rebase-merge || -d $gitdir/rebase-apply ]]; then
    problem 'Finish or abort the existing merge/rebase/cherry-pick/revert first'; return 1
  fi
  if [[ -z $ref ]]; then
    remote_info=$(git -C "$repo" ls-remote --symref origin HEAD) || remote_info=""
    ref=$(printf '%s\n' "$remote_info" | sed -n 's|^ref: refs/heads/\(.*\)[[:space:]]HEAD$|\1|p')
    if [[ -z $ref ]]; then ref=$DEFAULT_BRANCH; printf '[%s] origin/HEAD unavailable; using %s\n' "$repo" "$ref"; fi
  fi
  if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
    branch=$ref
    target=$(git -C "$repo" rev-parse --verify "refs/remotes/origin/$ref^{commit}") || return 1
  elif target=$(git -C "$repo" rev-parse --verify "refs/tags/$ref^{commit}" 2>/dev/null); then
    : # Tags and commit IDs are checked out detached.
  elif [[ $ref =~ ^[0-9a-fA-F]{7,64}$ ]] && target=$(git -C "$repo" rev-parse --verify "$ref^{commit}" 2>/dev/null); then
    :
  else
    problem "Ref not found on origin or as a local tag/commit: $ref"; return 1
  fi
  # Submodule working trees need their own update/data-loss policy.
  git -C "$repo" ls-tree -r "$target" > "$RUN_DIR/$index.tree" || return 1
  if git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$repo" ls-tree -r HEAD >> "$RUN_DIR/$index.tree" || return 1
  fi
  if grep -q '^160000 ' "$RUN_DIR/$index.tree"; then problem 'Submodules are not supported'; return 1; fi
  # Hidden index flags can conceal changes from status and make loss previews incomplete.
  git -C "$repo" -c core.quotePath=true ls-files -v > "$RUN_DIR/$index.flags" || return 1
  if grep -q '^[a-zS] ' "$RUN_DIR/$index.flags"; then
    problem 'Clear assume-unchanged/skip-worktree flags before updating'; return 1
  fi
  dirty=$(git -C "$repo" -c core.quotePath=true status --porcelain --untracked-files=no) || return 1
  find_blockers || { problem 'Cannot inspect untracked blockers'; return 1; }
  if [[ -n $branch ]] && git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    commits=$(git -C "$repo" log --oneline "$target..refs/heads/$branch") || return 1
  fi
  # Normal mode keeps local commits (ff-only); --force must match origin exactly.
  if [[ -n $dirty || -s $RUN_DIR/$index.blockers || ( $FORCE == true && -n $commits ) ]]; then
    confirm_losses || return 1
    if [[ -n $branch ]]; then
      step 'confirmed overwrite' git -C "$repo" checkout -f -B "$branch" "$target" || return 1
    else
      step 'confirmed overwrite' git -C "$repo" checkout -f --detach "$target" || return 1
    fi
  elif [[ -n $branch ]]; then
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      step checkout git -C "$repo" checkout --no-overwrite-ignore "$branch" || return 1
    else
      step checkout git -C "$repo" checkout --no-overwrite-ignore -b "$branch" "$target" || return 1
    fi
    step fast-forward git -C "$repo" merge --ff-only "$target" || return 1
  else
    step checkout git -C "$repo" checkout --no-overwrite-ignore --detach "$target" || return 1
  fi
}

run_one() {
  local index=$1
  printf '\n[%s] Processing\n' "${REPOS[$index]}"
  rm -f "$RUN_DIR/$index.error" || return 1
  sync_repo "$index"
}

collect_result() {
  local index=$1 status=$2
  if [[ $status == 0 ]]; then
    RESULTS[index]=success
  else
    RESULTS[index]=failed
    [[ -s $RUN_DIR/$index.error ]] || printf 'Git operation or local inspection failed; see output above\n' > "$RUN_DIR/$index.error"
  fi
}

wait_batch() {
  local slot index status
  for ((slot=0; slot<ACTIVE; slot++)); do
    index=${BATCH[$slot]}
    if wait "${PIDS[$slot]}"; then status=0; else status=$?; fi
    stop_worker "${PIDS[$slot]}" # Also stop any child left behind by a failed worker.
    if [[ $status -ge 128 ]]; then
      wait "${PIDS[$slot]}" 2>/dev/null || true
    fi
    cat "$RUN_DIR/$index.log" || fatal 'Cannot read repository output'
    collect_result "$index" "$status"
  done
  ACTIVE=0
}

process_all() {
  local index status
  # Bounded batches avoid a polling scheduler. Logs are printed per repository.
  [[ $JOBS == 1 ]] || set -m
  for ((index=0; index<COUNT; index++)); do
    if grep -Fxq -- "${REPOS[$index]}" "$RUN_DIR/exclusions"; then
      RESULTS[index]=excluded; continue
    fi
    if [[ $JOBS == 1 ]]; then
      if run_one "$index"; then status=0; else status=$?; fi
      collect_result "$index" "$status"
    else
      printf '[%s] Starting parallel job\n' "${REPOS[$index]}"
      INTERACTIVE=false GIT_TERMINAL_PROMPT=0 run_one "$index" > "$RUN_DIR/$index.log" 2>&1 < /dev/null 3<&- &
      PIDS[ACTIVE]=$! BATCH[ACTIVE]=$index
      ACTIVE=$((ACTIVE + 1))
      [[ $ACTIVE -lt $JOBS ]] || wait_batch
    fi
  done
  wait_batch
  set +m
}

review_failures() {
  local index choice status shown=false
  [[ $INTERACTIVE == true ]] || return 0
  for ((index=0; index<COUNT; index++)); do
    [[ ${RESULTS[$index]} == failed ]] || continue
    if [[ $shown == false ]]; then printf '\nFailed repositories:\n'; shown=true; fi
    printf '  %s: %s\n' "${REPOS[$index]}" "$(cat "$RUN_DIR/$index.error")"
  done
  for ((index=0; index<COUNT; index++)); do
    while [[ ${RESULTS[$index]} == failed ]]; do
      printf '[%s] retry / skip / ignore for future [r/s/i, default: skip]: ' "${REPOS[$index]}" >&4
      IFS= read -r choice <&3 || return 0
      case $choice in
        r|retry)
          if run_one "$index"; then status=0; else status=$?; fi
          collect_result "$index" "$status" ;;
        i|ignore|'ignore for future')
          # A leading separator also handles a hand-edited file without a final newline.
          if { [[ ! -s $EXCLUSIONS ]] || printf '\n'; } >> "$EXCLUSIONS" &&
             printf '%s\n' "${REPOS[$index]}" >> "$EXCLUSIONS"; then
            printf 'Excluded from future runs: %s\n' "${REPOS[$index]}"; break
          fi
          printf 'Cannot save exclusion to %s\n' "$EXCLUSIONS" >&2 ;;
        s|skip|'') break ;;
        *) printf 'Choose retry, skip, or ignore.\n' >&4 ;;
      esac
    done
  done
}

summary() {
  local index success=0 failed=0 excluded=0
  for ((index=0; index<COUNT; index++)); do
    case ${RESULTS[$index]} in
      success) success=$((success + 1)) ;;
      excluded) excluded=$((excluded + 1)) ;;
      *) failed=$((failed + 1)); printf 'FAILED %s: %s\n' "${REPOS[$index]}" "$(cat "$RUN_DIR/$index.error")" ;;
    esac
  done
  printf 'Summary: total=%s success=%s failed=%s excluded=%s\n' "$COUNT" "$success" "$failed" "$excluded"
  [[ $failed == 0 ]]
}

main() {
  parse_args "$@"
  RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pull-components.XXXXXX") || fatal 'Cannot create temporary directory'
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [[ -t 0 ]]; then INTERACTIVE=true; exec 3<&0 4>&2; fi
  load_manifest
  process_all
  review_failures
  summary
}

main "$@"
