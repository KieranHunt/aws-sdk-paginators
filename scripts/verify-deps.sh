#!/usr/bin/env bash
#
# A/B verification: run the paginator script on the baseline ref and on the
# current working tree, then require byte-identical outputs.
#
# Usage: scripts/verify-deps.sh <base-ref> [--author <login>]
#
# The PR author comes from --author or $PR_AUTHOR. Only a Dependabot-authored
# PR fails on an output diff; every other author gets an informational
# summary. A baseline failure or any setup failure always fails.
#
# Candidate is the current working tree, run in place. Its README.md and
# PAGINATORS.md are snapshotted before the run and restored afterwards.
set -euo pipefail

PR_AUTHOR="${PR_AUTHOR:-}"
BASE_REF=""

while [ $# -gt 0 ]; do
  case "$1" in
    --author)
      [ $# -ge 2 ] || { echo "ERROR: --author needs a value" >&2; exit 1; }
      PR_AUTHOR="$2"
      shift 2
      ;;
    --author=*)
      PR_AUTHOR="${1#--author=}"
      shift
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      exit 1
      ;;
    *)
      [ -z "$BASE_REF" ] || { echo "ERROR: exactly one base ref expected" >&2; exit 1; }
      BASE_REF="$1"
      shift
      ;;
  esac
done

[ -n "$BASE_REF" ] || { echo "Usage: scripts/verify-deps.sh <base-ref> [--author <login>]" >&2; exit 1; }

log() { printf '%s\n' "$*"; }

# mise-action sets MISE_TRUSTED_CONFIG_PATHS to the checkout dir only; worktrees
# elsewhere would be treated as untrusted and their tools invisible, so each side
# must be appended explicitly.
add_trusted() {
  case ":${MISE_TRUSTED_CONFIG_PATHS:-}:" in
    *":$1:"*) ;;
    *) export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:+$MISE_TRUSTED_CONFIG_PATHS:}$1" ;;
  esac
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "not inside a git repository"
cd "$REPO_ROOT"

OUTPUT_FILES=(README.md PAGINATORS.md)

git rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null || fail "base ref not found: $BASE_REF"

SDK_DIR="${SDK_DIR:-$HOME/.cache/aws-sdk-java-v2}"
[ -d "$SDK_DIR" ] || fail "SDK clone not found at $SDK_DIR (set SDK_DIR or clone aws-sdk-java-v2 there)"

if command -v mise >/dev/null 2>&1; then
  MISE_BIN="mise"
elif [ -x "$HOME/.local/bin/mise" ]; then
  MISE_BIN="$HOME/.local/bin/mise"
else
  fail "mise not found on PATH or at ~/.local/bin/mise"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/verify-deps.XXXXXX")"
BASELINE_DIR=""

# <base-ref> as a worktree; candidate is this checkout, run in place.
git worktree add --quiet --detach "$TMP_DIR/baseline" "$BASE_REF" || fail "could not create baseline worktree for $BASE_REF"
BASELINE_DIR="$TMP_DIR/baseline"
add_trusted "$REPO_ROOT"
add_trusted "$BASELINE_DIR"

# shellcheck disable=SC2329
cleanup() {
  rc=$?
  if [ -n "$BASELINE_DIR" ]; then
    git -C "$REPO_ROOT" worktree remove --force "$BASELINE_DIR" >/dev/null 2>&1 \
      || rm -rf "$BASELINE_DIR"
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
  fi
  for f in "${OUTPUT_FILES[@]}"; do
    if [ -f "$TMP_DIR/candidate-$f.before" ]; then
      cp "$TMP_DIR/candidate-$f.before" "$REPO_ROOT/$f"
    fi
  done
  rm -f "$REPO_ROOT/aws-sdk-java-v2"
  rm -rf "$TMP_DIR"
  return "$rc"
}
trap 'cleanup; exit $?' EXIT
trap 'exit 130' INT TERM

link_sdk() {
  rm -f "$1/aws-sdk-java-v2"
  ln -s "$SDK_DIR" "$1/aws-sdk-java-v2"
}

# Runs in a subshell so mise resolves the tools of that directory.
prepare_side() {
  (
    cd "$1"
    "$MISE_BIN" trust "$1" >/dev/null 2>&1 || true
    "$MISE_BIN" install --locked bun
    log "[$2] bun $("$MISE_BIN" exec -- bun --version)"
    "$MISE_BIN" exec -- bun install --frozen-lockfile
  )
}

# Output goes to the log file only: the script prints the full paginator
# catalogue, which is thousands of lines. Failures are shown by the caller.
run_strict() {
  (
    cd "$1"
    "$MISE_BIN" exec -- bun run find-aws-sdk-paginators.ts >"$2" 2>&1
  )
}

log_counts() {
  local side="$1" counts="$2" files paginators services
  files="${counts%%|*}"
  counts="${counts#*|}"
  paginators="${counts%%|*}"
  services="${counts#*|}"
  log "[$side] $files files, $paginators paginators, $services services"
}

extract_counts() {
  local files paginators services
  files=$(sed -n 's/Found \([0-9]*\) paginators-1\.json files.*/\1/p' "$1" | tail -1)
  # e.g. "Generated PAGINATORS.md with 3808 paginators from 378 services"
  counts=$(sed -n 's/.*Generated PAGINATORS\.md with \([0-9]*\) paginators from \([0-9]*\) services.*/\1 \2/p' "$1" | tail -1)
  paginators="${counts%% *}"
  services="${counts#* }"
  printf '%s|%s|%s' "${files:-?}" "${paginators:-?}" "${services:-?}"
}

write_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    echo "## verify-deps"
    echo ""
    echo "| | services | paginators | files |"
    echo "|---|---|---|---|"
    echo "| baseline | $1 | $2 | $3 |"
    echo "| candidate | $4 | $5 | $6 |"
    echo ""
    echo "Author: \`${PR_AUTHOR:-<unset>}\`"
    echo ""
    echo "**Verdict:** $7"
  } >> "$GITHUB_STEP_SUMMARY"
}

log "=== Baseline: $BASE_REF ==="
link_sdk "$BASELINE_DIR"
prepare_side "$BASELINE_DIR" "baseline" || fail "baseline setup failed (mise install / bun install)"
run_strict "$BASELINE_DIR" "$TMP_DIR/baseline.log" || { tail -n 40 "$TMP_DIR/baseline.log"; fail "baseline strict run failed (always fatal)"; }
IFS='|' read -r b_files b_paginators b_services <<< "$(extract_counts "$TMP_DIR/baseline.log")"
log_counts baseline "$b_files|$b_paginators|$b_services"

log ""
log "=== Candidate: working tree ==="
for f in "${OUTPUT_FILES[@]}"; do
  cp "$REPO_ROOT/$f" "$TMP_DIR/candidate-$f.before"
done
link_sdk "$REPO_ROOT"
prepare_side "$REPO_ROOT" "candidate" || fail "candidate setup failed (mise install / bun install --frozen-lockfile)"

(
  cd "$REPO_ROOT"
  "$MISE_BIN" exec -- bun run typecheck
) || fail "candidate typecheck failed (bun check)"

run_strict "$REPO_ROOT" "$TMP_DIR/candidate.log" || { tail -n 40 "$TMP_DIR/candidate.log"; fail "candidate strict run failed"; }
IFS='|' read -r c_files c_paginators c_services <<< "$(extract_counts "$TMP_DIR/candidate.log")"
log_counts candidate "$c_files|$c_paginators|$c_services"

outputs_match=true
for f in "${OUTPUT_FILES[@]}"; do
  # cmp for byte-identical comparison; portable across BSD and GNU.
  if cmp -s "$BASELINE_DIR/$f" "$REPO_ROOT/$f"; then
    log "$f: identical"
  else
    log "$f: DIFFERS"
    outputs_match=false
  fi
done

if [ "$outputs_match" = true ]; then
  write_summary "$b_services" "$b_paginators" "$b_files" \
    "$c_services" "$c_paginators" "$c_files" "outputs identical"
  log "Verdict: outputs identical"
  exit 0
fi

if [ "$PR_AUTHOR" = "dependabot[bot]" ]; then
  write_summary "$b_services" "$b_paginators" "$b_files" \
    "$c_services" "$c_paginators" "$c_files" "FAILED — output diff for Dependabot PR"
  fail "outputs differ for a Dependabot PR"
fi

write_summary "$b_services" "$b_paginators" "$b_files" \
  "$c_services" "$c_paginators" "$c_files" "output diff (informational; author is not Dependabot)"
log "Verdict: outputs differ, but author '${PR_AUTHOR:-<unset>}' is not Dependabot[bot] — informational only"
exit 0
