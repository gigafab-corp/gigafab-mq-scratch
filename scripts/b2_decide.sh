#!/usr/bin/env bash
# b2_decide.sh — B2 FR3 skip decision (B2 design §2).
#
# Runs from the MERGE_BASE blob (never the PR worktree): the workflow
# step executes it as `git show "$MERGE_BASE:scripts/b2_decide.sh" | bash`.
# A PR therefore cannot rewrite its own skip decision.
#
# Inputs (env):
#   GIGAFAB_BASE_SHA      base SHA for merge-base (fallback: origin/main)
#   B2_ANCHOR_HASH        vars.B2_LAST_FULL_INPUTS_HASH
#   B2_ANCHOR_SHA         vars.B2_LAST_FULL_SHA
#   B2_ANCHOR_AT          vars.B2_LAST_FULL_AT (ISO 8601 UTC)
#   B2_ANCHOR_RUN_ID      vars.B2_LAST_FULL_RUN_ID
#   B2_FORCE_FULL         "true" if the PR carries the b2-force-full label
#   GITHUB_OUTPUT / GITHUB_STEP_SUMMARY  (runner-provided; if unset, the
#   decision and the summary go to stdout instead, for local testing)
#
# Decision (four-way conjunction; any failure means RUN):
#   C1  MERGE_BASE..HEAD diff touches no I1-I5 path
#   C2  input hash at MERGE_BASE == B2_ANCHOR_HASH
#   C3  B2_ANCHOR_AT within 7 days
#   C4  B2_ANCHOR_RUN_ID non-empty
#   plus: b2-force-full label forces RUN; empty diff forces RUN.
#
# Discipline (design §2.3): this script ALWAYS exits 0 and never fails
# the job; any internal error writes the run value first. The skip value
# is emitted by exactly one call site below — the line reached only when
# C1-C4 have all passed. Every other path emits the run value.
set -uo pipefail

FRESH_SECONDS=604800  # 7 days

# --- outputs -------------------------------------------------------------
# $1 = "true" (run FR3) or "false" (skip FR3). The skip value is passed
# here only from the single all-pass call site at the bottom of main().
write_decision() {
  local value="$1"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'run_fr3=%s\n' "$value" >>"$GITHUB_OUTPUT"
  else
    printf 'run_fr3=%s\n' "$value"
  fi
}

# $1 = SKIP|RUN, $2 = reason line, $3 = inputs hash (may be empty),
# $4 = head short, $5 = merge-base short.
write_record() {
  local decision="$1" reason="$2" inputs_hash="$3" head_short="$4" base_short="$5"
  local anchor_sha_short="${B2_ANCHOR_SHA:-}"
  anchor_sha_short="${anchor_sha_short:0:7}"
  {
    echo "B2 decision: $decision"
    echo "  reason: $reason"
    echo "  head: $head_short  merge-base: $base_short"
    echo "  inputs-hash@merge-base: ${inputs_hash:-<unavailable>}"
    echo "  anchor: run ${B2_ANCHOR_RUN_ID:-<none>} @ ${anchor_sha_short:-<none>} @ ${B2_ANCHOR_AT:-<none>}"
    echo "  anchor-inputs-hash: ${B2_ANCHOR_HASH:-<none>}"
    echo "  force-label: $([ "${B2_FORCE_FULL:-false}" = "true" ] && echo "yes (b2-force-full)" || echo "no")"
  } > "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
  echo "::notice::B2 decision: $decision ($reason)" >&2
  echo "::notice::B2 anchor: run ${B2_ANCHOR_RUN_ID:-<none>} @ ${anchor_sha_short:-<none>}" >&2
}

# Emit a RUN decision with its reason, then return 0. Used by every
# non-skip path.
decide_run() {
  local reason="$1" inputs_hash="${2:-}" head_short="${3:-<unknown>}" base_short="${4:-<unknown>}"
  write_decision true
  write_record RUN "$reason" "$inputs_hash" "$head_short" "$base_short"
}

# --- main ----------------------------------------------------------------
main() {
  local head_short base_short merge_base inputs_hash reason hit

  head_short="$(git rev-parse --short HEAD 2>/dev/null || echo "<unknown>")"

  # Force-full label: always run, no conditions evaluated.
  if [ "${B2_FORCE_FULL:-false}" = "true" ]; then
    decide_run "force-full label (b2-force-full)" "" "$head_short" "<unknown>"
    return 0
  fi

  # Merge-base. Uncomputable -> run (never fail the job).
  if ! merge_base="$(git merge-base "${GIGAFAB_BASE_SHA:-origin/main}" HEAD 2>/dev/null)"; then
    decide_run "merge-base unavailable" "" "$head_short" "<unknown>"
    return 0
  fi
  base_short="$(git rev-parse --short "$merge_base" 2>/dev/null || echo "<unknown>")"

  # C1: diff must touch no input path. Empty diff -> run (fail-closed).
  local diff_out
  if ! diff_out="$(git diff --name-only --no-renames "${merge_base}..HEAD" 2>/dev/null)"; then
    decide_run "diff unavailable" "" "$head_short" "$base_short"
    return 0
  fi
  if [ -z "$diff_out" ]; then
    decide_run "empty diff" "" "$head_short" "$base_short"
    return 0
  fi
  hit=""
  while IFS= read -r p; do
    case "$p" in
      services/mm-failover/*|scripts/deploy_mm_failover.sh|tests/mm_failover_provenance_acceptance.sh|.github/workflows/gate_a.yml|scripts/gate_assertion_guard.sh)
        hit="$p"
        break
        ;;
    esac
  done <<<"$diff_out"
  if [ -n "$hit" ]; then
    decide_run "input changed: $hit" "" "$head_short" "$base_short"
    return 0
  fi

  # Input hash at the merge-base, computed by the base-blob hash script.
  if ! inputs_hash="$(git show "$merge_base:scripts/b2_input_hash.sh" 2>/dev/null | bash -s -- "$merge_base" 2>/dev/null)"; then
    decide_run "input hash undefined at merge-base" "" "$head_short" "$base_short"
    return 0
  fi
  if [ -z "$inputs_hash" ]; then
    decide_run "input hash empty at merge-base" "" "$head_short" "$base_short"
    return 0
  fi

  # C2: anchor hash must match the merge-base inputs hash.
  if [ -z "${B2_ANCHOR_HASH:-}" ] || [ "$inputs_hash" != "$B2_ANCHOR_HASH" ]; then
    decide_run "anchor hash mismatch" "$inputs_hash" "$head_short" "$base_short"
    return 0
  fi

  # C4 (checked before C3 so the reason names the missing piece first):
  # anchor run id must be non-empty.
  if [ -z "${B2_ANCHOR_RUN_ID:-}" ]; then
    decide_run "anchor run id missing" "$inputs_hash" "$head_short" "$base_short"
    return 0
  fi

  # C3: anchor timestamp must parse and be within 7 days (and not future).
  local anchor_epoch now_epoch
  if ! anchor_epoch="$(date -u -d "${B2_ANCHOR_AT:-}" +%s 2>/dev/null)"; then
    decide_run "anchor timestamp unparsable" "$inputs_hash" "$head_short" "$base_short"
    return 0
  fi
  now_epoch="$(date -u +%s)"
  if [ "$anchor_epoch" -gt "$now_epoch" ] || [ $((now_epoch - anchor_epoch)) -gt "$FRESH_SECONDS" ]; then
    decide_run "anchor stale" "$inputs_hash" "$head_short" "$base_short"
    return 0
  fi

  # C1-C4 all passed. This is the ONLY skip emission in this file.
  reason="inputs-unchanged + anchor-match"
  write_decision false
  write_record SKIP "$reason" "$inputs_hash" "$head_short" "$base_short"
  return 0
}

main
exit 0
