#!/usr/bin/env bash
# scripts/gate_assertion_guard.sh — assertion-count wrapper for SUITE tests.
#
# S-01-13 (Phase 1, observe): a SUITE test that exits 0 while asserting
# nothing (PASS=0, or no PASS= tally line at all) is a hollow pass — today
# gate-a only looks at the exit code, so it counts as green. This wrapper
# runs a test, replays its output, parses the LAST `PASS=<n> FAIL=<m>` tally
# line, and decides:
#
#   test exits non-zero            -> fail (pass the exit code through)
#   test exits 0, PASS >= 1        -> pass
#   test exits 0, PASS == 0        -> zero-assertion
#   test exits 0, no PASS= line    -> zero-assertion (fail-closed: a test
#                                     that prints no tally cannot prove it
#                                     asserted anything)
#   test exits 0, FAIL >= 1        -> masked failure (M5): the tally
#                                     reports failures the exit code hides.
#                                     Checked BEFORE the zero-assertion rule:
#                                     a test that failed assertions did assert
#                                     something — it just cannot report red.
#
# Modes (S-01-13 §2.5, two-phase rollout):
#   observe (default, Phase 1): zero-assertion and masked failure only emit
#     a `zero-assertion-observed` / `masked-failure-observed` notice
#     (workflow annotation + step summary when present) and exit 0. They
#     never change a gate verdict.
#   enforce (Phase 2): zero-assertion and masked failure exit 1 (the step
#     goes red).
#
# Mode selection: `--mode observe|enforce` flag, else the
# GATE_ASSERTION_GUARD_MODE environment variable, else `observe`.
# An invalid mode is a hard error (exit 2) — never silently default.
#
# Usage: bash scripts/gate_assertion_guard.sh [--mode observe|enforce] <test-script> [args...]
# The wrapper is test-agnostic: it does not change test semantics, it only
# reads the tally the test itself prints. SKIP does not count as an assertion.

set -uo pipefail

MODE="${GATE_ASSERTION_GUARD_MODE:-observe}"
if [ "${1:-}" = "--mode" ]; then
  [ $# -ge 2 ] || { echo "gate_assertion_guard: --mode needs a value (observe|enforce)" >&2; exit 2; }
  MODE="$2"
  shift 2
fi
case "$MODE" in
  observe|enforce) ;;
  *) echo "gate_assertion_guard: invalid mode '$MODE' (want observe|enforce)" >&2; exit 2 ;;
esac

if [ $# -lt 1 ]; then
  echo "gate_assertion_guard: usage: bash scripts/gate_assertion_guard.sh [--mode observe|enforce] <test-script> [args...]" >&2
  exit 2
fi
TEST_SCRIPT="$1"
shift

if [ ! -f "$TEST_SCRIPT" ]; then
  echo "gate_assertion_guard: test script not found: $TEST_SCRIPT" >&2
  exit 1
fi

GUARD_TMP="$(mktemp "${TMPDIR:-/tmp}/gate-assertion-guard.XXXXXX")" || exit 1
trap 'rm -f "$GUARD_TMP"' EXIT

# Run the test, capturing everything; replay the log verbatim so the step
# log still shows the test output (CI reads the log, not this script).
bash "$TEST_SCRIPT" "$@" >"$GUARD_TMP" 2>&1
TEST_RC=$?
cat "$GUARD_TMP"

# The tally is the LAST `PASS=<n> FAIL=<m>` line. Tests may print tally
# lines mid-run (mutation sub-runs, failing checkpoints); only the final
# line is the run total. Leading whitespace is allowed (some tests indent
# the tally); a trailing `SKIP=<k>` is allowed (the regex is unanchored).
TALLY_LINE="$(grep -E '^[[:space:]]*PASS=[0-9]+ FAIL=[0-9]+' "$GUARD_TMP" | tail -n 1 || true)"

if [ "$TEST_RC" -ne 0 ]; then
  # The test already failed on its own terms; pass the failure through.
  # (A failing test's tally, if any, is not a zero-assertion question.)
  echo "gate_assertion_guard: $TEST_SCRIPT exited $TEST_RC (test failed; verdict=red)"
  exit "$TEST_RC"
fi

if [ -z "$TALLY_LINE" ]; then
  MSG="zero-assertion-observed: $TEST_SCRIPT exited 0 with no PASS= tally line (no assertion was proven)"
  if [ "$MODE" = "enforce" ]; then
    echo "::error title=zero-assertion::$MSG" >&2
    echo "gate_assertion_guard: $TEST_SCRIPT verdict=red (mode=enforce, no tally)"
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -w "${GITHUB_STEP_SUMMARY:-/dev/null}" ] && printf '%s\n' "- $MSG" >>"$GITHUB_STEP_SUMMARY"
    exit 1
  fi
  echo "::notice title=zero-assertion-observed::$MSG"
  echo "gate_assertion_guard: $TEST_SCRIPT verdict=pass (mode=observe, no tally)"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -w "${GITHUB_STEP_SUMMARY:-/dev/null}" ] && printf '%s\n' "- $MSG" >>"$GITHUB_STEP_SUMMARY"
  exit 0
fi

PASS_N="$(printf '%s\n' "$TALLY_LINE" | sed -E 's/^[[:space:]]*PASS=([0-9]+) FAIL=[0-9]+.*$/\1/')"
FAIL_N="$(printf '%s\n' "$TALLY_LINE" | sed -E 's/^[[:space:]]*PASS=[0-9]+ FAIL=([0-9]+).*$/\1/')"
if [ "$FAIL_N" -gt 0 ]; then
  MSG="masked-failure-observed: $TEST_SCRIPT exited 0 with FAIL=$FAIL_N (PASS=$PASS_N) — the tally reports failures the exit code hides"
  if [ "$MODE" = "enforce" ]; then
    echo "::error title=masked-failure::$MSG" >&2
    echo "gate_assertion_guard: $TEST_SCRIPT verdict=red (mode=enforce, FAIL=$FAIL_N with rc=0)"
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -w "${GITHUB_STEP_SUMMARY:-/dev/null}" ] && printf '%s\n' "- $MSG" >>"$GITHUB_STEP_SUMMARY"
    exit 1
  fi
  echo "::notice title=masked-failure-observed::$MSG"
  echo "gate_assertion_guard: $TEST_SCRIPT verdict=pass (mode=observe, FAIL=$FAIL_N with rc=0)"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -w "${GITHUB_STEP_SUMMARY:-/dev/null}" ] && printf '%s\n' "- $MSG" >>"$GITHUB_STEP_SUMMARY"
  exit 0
fi
if [ "$PASS_N" -eq 0 ]; then
  MSG="zero-assertion-observed: $TEST_SCRIPT exited 0 with PASS=0 (no assertion executed)"
  if [ "$MODE" = "enforce" ]; then
    echo "::error title=zero-assertion::$MSG" >&2
    echo "gate_assertion_guard: $TEST_SCRIPT verdict=red (mode=enforce, PASS=0)"
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -w "${GITHUB_STEP_SUMMARY:-/dev/null}" ] && printf '%s\n' "- $MSG" >>"$GITHUB_STEP_SUMMARY"
    exit 1
  fi
  echo "::notice title=zero-assertion-observed::$MSG"
  echo "gate_assertion_guard: $TEST_SCRIPT verdict=pass (mode=observe, PASS=0)"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -w "${GITHUB_STEP_SUMMARY:-/dev/null}" ] && printf '%s\n' "- $MSG" >>"$GITHUB_STEP_SUMMARY"
  exit 0
fi

echo "gate_assertion_guard: $TEST_SCRIPT PASS=$PASS_N (mode=$MODE, verdict=pass)"
exit 0
