#!/usr/bin/env bash
# b2_input_hash.sh — B2 evidence-anchor input hash (B2 design §2.2).
#
# Usage: b2_input_hash.sh <ref> [repo-dir]
#   Prints the 64-char sha256 of the sorted "<path>=<blobsha>" lines for
#   the FR3 input set and exits 0:
#     I1  prefix services/mm-failover/ (recursive, every file)
#     I2  scripts/deploy_mm_failover.sh
#     I3  tests/mm_failover_provenance_acceptance.sh
#     I4  .github/workflows/gate_a.yml
#     I5  scripts/gate_assertion_guard.sh
#   Exits 2 (no output) if any input path is missing at <ref> — the hash
#   is then undefined and the caller must treat it as RUN (decide script)
#   or do-not-write (anchor cron). This is the ONLY implementation of the
#   hash: the decide script and the anchor cron both call this file, never
#   a second copy (two copies drift; drift is a wrong skip or a wrong run).
set -uo pipefail

REF="${1:-}"
REPO="${2:-.}"
if [ -z "$REF" ]; then
  echo "usage: b2_input_hash.sh <ref> [repo-dir]" >&2
  exit 2
fi

out=""

# I1: prefix, recursive. --format gives "<blobsha> <path>" per line.
tree_out="$(git -C "$REPO" ls-tree -r --format='%(objectname) %(path)' "$REF" -- services/mm-failover/ 2>/dev/null)" || exit 2
if [ -z "$tree_out" ]; then
  # Prefix absent or empty at this ref: hash undefined.
  exit 2
fi
while IFS= read -r line; do
  sha="${line%% *}"
  path="${line#* }"
  out+="${path}=${sha}"$'\n'
done <<<"$tree_out"

# I2-I5: one blob sha each. Any missing file makes the hash undefined.
for f in scripts/deploy_mm_failover.sh tests/mm_failover_provenance_acceptance.sh .github/workflows/gate_a.yml scripts/gate_assertion_guard.sh; do
  sha="$(git -C "$REPO" rev-parse --verify --quiet "$REF:$f" 2>/dev/null)" || exit 2
  if [ -z "$sha" ]; then
    exit 2
  fi
  out+="${f}=${sha}"$'\n'
done

printf '%s' "$out" | LC_ALL=C sort | sha256sum | awk '{print $1}'
