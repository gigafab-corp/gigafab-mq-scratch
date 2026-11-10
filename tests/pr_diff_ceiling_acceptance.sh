#!/usr/bin/env bash
# PR diff ceiling — the "small PR" convention, as a machine gate (FAST_RED 14/14).
#
# The defect. "Keep PRs small (~200 lines)" was a convention, not a gate: a
# 1,200-line PR merged exactly like a 40-line one, and the only thing standing
# between a sprawling PR and main was a reviewer's eyeball. The merge-gate
# literature (Automater, "AI Agent Merge Gates") lists a diff cap as one of
# the six cheap, decisive merge gates. This card is that gate.
#
# The caps. `additions <= 500` AND `changed_files <= 20`; either one over the
# line is red. Calibrated, not guessed: the last 30 merged PRs on main
# (2026-11-06–11-07, see scratch/diff-cap-design/merged30.tsv) have additions
# median 40 / p80 360 / p90 680, files median 3.5 / p90 16. 500/20 passes
# 25/30 (83%) and blocks only the five genuinely large PRs (all 600+
# additions: #2354, #2313, #2122, #2208, #2266). The 400/15 example in the
# trend report would have blocked #2340 (402 lines — over by 2, cliff noise)
# and #2335 (16 files, 198 additions — a shallow docs sweep). Additions, not
# total lines: #2299 deleted 459 lines and added 2 — a cleanup, not a risk.
#
# Waiver. Over the cap, a PR passes only with the `ceiling-waived` label AND
# a reason in a PR comment (the machine reads the label; a human reads the
# reason). The label is read from the event payload, so it is the label set
# at trigger time — a label added after the run starts needs a gate-a re-run
# to be picked up. The labeler must not be the PR author.
#
# Batch drafts (Mergify merge queue). A batch draft tests several PRs as one
# tip, so the whole-diff measurement sums the constituents and fails any
# combined diff over cap — deterministically, even when each PR is small
# (F-1: #2635 +220 plus #2630 +445 = 665). The card therefore detects a
# batch run (all three must hold: payload author mergify[bot], head ref
# mergify/merge-queue/*, PR body carries the Mergify metadata block) and
# measures each constituent separately: git diff <merge>^1 <merge> for every
# "Merge of #N" commit on the first-parent chain back to checking_base_sha.
# Each constituent gets its own cap verdict, and an over-cap constituent
# passes only if IT carries ceiling-waived (read live via the API with
# $GH_TOKEN — the batch PR's labels are not the constituents' labels, so
# the payload cannot supply them). Any structural mismatch (chain vs body
# list) falls back to whole-diff measurement. A run that is not a batch
# takes today's path, byte-identical. API failure degrades per-constituent
# (waiver treated as absent, loudly) and never fails the whole card.
#
# Hermetic except for git and one read-only API call: fixtures are built
# under $TMPDIR and removed on exit; the source tree is never written. The
# live verdict reads the real checkout. `jq` parses the payload (already
# used by FAST_RED tests). The waiver lookup (batch path only, over-cap
# constituents only) is a GET on /pulls/<n> labels; the token is never
# printed, and a fixture file (GIGAFAB_WAIVER_FIXTURE) stubs it in tests.
#
# Measurement. Local `git diff --numstat <base> <head>`, zero network, zero
# token — like the other 13 FAST_RED cards. Base SHA comes from the event
# payload (`.pull_request.base.sha`); head is HEAD. Local numbers are
# authoritative: what a reviewer sees in `git diff --stat` is what this card
# computes, so there is nothing to argue about.
#
# Contexts. In CI (gate-a, pull_request event) the payload is authoritative.
# Locally (no payload) the base falls back to merge-base resolution, exactly
# like the whitespace gate: GIGAFAB_BASE_SHA, then origin/main, then main.
# A payload that EXISTS but carries no `.pull_request` is fail-closed (red,
# "no PR context") — a malformed event must never silently pass. A payload
# file that cannot be read, or a base that cannot be resolved at all, is
# likewise fail-closed.
# No pipe feeds an early-exit reader (#2223): outputs are captured first,
# then grepped from a variable or a file.

set -uo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT" || exit 1

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$1"; }

CAP_ADDITIONS=500
CAP_FILES=20
WAIVER_LABEL=ceiling-waived

echo "=== pr diff ceiling (FAST_RED 14/14) ==="
echo "cap: $CAP_ADDITIONS additions / $CAP_FILES files (waiver: $WAIVER_LABEL)"

# ---------------------------------------------------------------------------
# check_diff <base> <head> <event-file-or-empty>
# Measures the diff and renders the verdict. Prints one verdict line.
# Returns 0 = pass (within cap, or waived), 1 = fail (over cap, no waiver),
# 2 = environment error (cannot measure — caller turns this into fail-closed).
# ---------------------------------------------------------------------------
check_diff() {
  local base="$1" head="$2" event_file="$3"
  local numstat additions files waived
  numstat=$(git diff --numstat "$base" "$head" 2>/dev/null) || return 2
  # numstat lines: "<insertions>\t<deletions>\t<path>"; binary files are "-\t-".
  # Tab-separated, so a filename with spaces cannot shift the first two fields.
  read -r additions files <<<"$(printf '%s\n' "$numstat" | awk -F'\t' 'NF { if ($1 != "-") add += $1; n++ } END { print (add+0) " " (n+0) }')"
  waived=0
  if [ -n "$event_file" ] && [ -f "$event_file" ]; then
    local labels
    labels=$(jq -r '.pull_request.labels[]?.name // empty' "$event_file" 2>/dev/null) || return 2
    if grep -qxF "$WAIVER_LABEL" <<<"$labels"; then
      waived=1
    fi
  fi
  if [ "$additions" -le "$CAP_ADDITIONS" ] && [ "$files" -le "$CAP_FILES" ]; then
    printf 'diff ceiling: %s additions / %s files (cap %s / %s)\n' "$additions" "$files" "$CAP_ADDITIONS" "$CAP_FILES"
    return 0
  fi
  if [ "$waived" -eq 1 ]; then
    printf 'diff ceiling: waived by %s (%s additions / %s files) — a reviewer must still check the reason comment\n' "$WAIVER_LABEL" "$additions" "$files"
    return 0
  fi
  printf 'diff ceiling: %s additions / %s files exceeds cap %s / %s — split the PR, or write a waiver reason in a PR comment and ask for the %s label (then re-run gate-a)\n' "$additions" "$files" "$CAP_ADDITIONS" "$CAP_FILES" "$WAIVER_LABEL"
  return 1
}

# ---------------------------------------------------------------------------
# measure_diff <base> <head> — prints "<additions> <files>" for the diff,
# or returns 2 if git cannot measure it. Same numstat accounting as
# check_diff (binary files count as files, add nothing).
# ---------------------------------------------------------------------------
measure_diff() {
  local base="$1" head="$2" numstat
  numstat=$(git diff --numstat "$base" "$head" 2>/dev/null) || return 2
  printf '%s\n' "$numstat" | awk -F'\t' 'NF { if ($1 != "-") add += $1; n++ } END { print (add+0) " " (n+0) }'
}

# ---------------------------------------------------------------------------
# constituent_waived <pr-number> — 0 if PR <n> carries ceiling-waived.
# Fixture seam: if GIGAFAB_WAIVER_FIXTURE points at a file listing waived
# PR numbers (one per line), that file is authoritative and no network is
# touched. Otherwise a live API read with $GH_TOKEN (needs
# pull-requests: read on the workflow). Any API failure degrades to
# "unwaived for this constituent only" with a loud notice — it never fails
# the whole card, and the token is never printed.
# ---------------------------------------------------------------------------
constituent_waived() {
  local pr="$1"
  if [ -n "${GIGAFAB_WAIVER_FIXTURE:-}" ] && [ -f "$GIGAFAB_WAIVER_FIXTURE" ]; then
    if grep -qx "$pr" "$GIGAFAB_WAIVER_FIXTURE" 2>/dev/null; then
      return 0
    fi
    return 1
  fi
  local token="${GH_TOKEN:-}"
  if [ -z "$token" ]; then
    printf '    note: waiver lookup unavailable for #%s (no GH_TOKEN) — treating as unwaived\n' "$pr"
    return 1
  fi
  local repo="${GIGAFAB_REPO:-}"
  if [ -z "$repo" ]; then
    repo=$(git remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]([^/]+/[^/]+)(\.git)?$#\1#')
  fi
  if [ -z "$repo" ]; then
    printf '    note: waiver lookup unavailable for #%s (cannot determine repo slug) — treating as unwaived\n' "$pr"
    return 1
  fi
  local labels_file code labels
  labels_file=$(mktemp "${TMPDIR:-/tmp}/prdc-labels.XXXXXX") || {
    printf '    note: waiver lookup unavailable for #%s (mktemp failed) — treating as unwaived\n' "$pr"
    return 1
  }
  code=$(curl -sS -o "$labels_file" -w '%{http_code}' -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$repo/pulls/$pr" 2>/dev/null) || code=""
  if [ "$code" != "200" ]; then
    printf '    note: waiver lookup unavailable for #%s (API HTTP %s) — treating as unwaived\n' "$pr" "${code:-curl-failed}"
    rm -f "$labels_file"
    return 1
  fi
  labels=$(jq -r '.labels[]?.name // empty' "$labels_file" 2>/dev/null) || {
    printf '    note: waiver lookup unavailable for #%s (unparsable API response) — treating as unwaived\n' "$pr"
    rm -f "$labels_file"
    return 1
  }
  rm -f "$labels_file"
  if grep -qxF "$WAIVER_LABEL" <<<"$labels"; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# detect_batch <event-file> — 0 if this run is a Mergify batch draft.
# All three signals must hold: (i) payload author is mergify[bot];
# (ii) head ref matches mergify/merge-queue/*; (iii) the PR body carries
# the Mergify metadata block (checking_base_sha + pull_requests: list).
# A human PR can fake a branch name or body text but not user.login, so a
# batch-shaped human PR must never get the per-merge-commit treatment.
# ---------------------------------------------------------------------------
detect_batch() {
  local event_file="$1" author ref body
  [ -n "$event_file" ] && [ -f "$event_file" ] || return 1
  author=$(jq -r '.pull_request.user.login // empty' "$event_file" 2>/dev/null) || return 1
  [ "$author" = "mergify[bot]" ] || return 1
  ref=$(jq -r '.pull_request.head.ref // empty' "$event_file" 2>/dev/null) || return 1
  case "$ref" in
    mergify/merge-queue/*) ;;
    *) return 1 ;;
  esac
  body=$(jq -r '.pull_request.body // empty' "$event_file" 2>/dev/null) || return 1
  grep -q 'checking_base_sha:' <<<"$body" || return 1
  grep -q 'pull_requests:' <<<"$body" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# batch_constituents <event-file> — prints "base:<sha>" on the first line,
# then the listed PR numbers, one per line, in body order. Returns 1 if
# the metadata block cannot be parsed.
# ---------------------------------------------------------------------------
batch_constituents() {
  local event_file="$1" body base
  body=$(jq -r '.pull_request.body // empty' "$event_file" 2>/dev/null) || return 1
  base=$(grep -o 'checking_base_sha: [0-9a-f]*' <<<"$body" | head -n 1 | awk '{print $2}')
  [ -n "$base" ] || return 1
  printf 'base:%s\n' "$base"
  grep -o '^  - number: [0-9][0-9]*' <<<"$body" | awk '{print $3}'
}

# ---------------------------------------------------------------------------
# resolve_batch_tip <head> <event-file> — prints the effective batch tip.
# The checkout for pull_request events is the synthetic merge ref: its
# first parent is the base and its second parent is the PR head, so HEAD
# itself sits one synthetic merge above the "Merge of #N" chain (observed
# in production run 42826694507: HEAD a051944 "Merge 75434119… into
# e42f47bd…"). The payload carries the real tip in .pull_request.head.sha;
# use it when it is an ancestor of HEAD (or HEAD itself), else HEAD.
# ---------------------------------------------------------------------------
resolve_batch_tip() {
  local head="$1" event_file="$2" tip
  tip=$(jq -r '.pull_request.head.sha // empty' "$event_file" 2>/dev/null) || tip=""
  if [ -n "$tip" ] && git merge-base --is-ancestor "$tip" "$head" 2>/dev/null; then
    printf '%s' "$tip"
    return 0
  fi
  printf '%s' "$head"
  return 0
}

# ---------------------------------------------------------------------------
# check_batch <head> <event-file>
# Decomposes a Mergify batch run into per-constituent ceiling verdicts.
# Returns 0 = every constituent passes (or is waived); 1 = a constituent
# is over cap without a waiver; 2 = structural mismatch — the caller falls
# back to whole-diff measurement (today's behavior, never a silent pass).
# ---------------------------------------------------------------------------
check_batch() {
  local head="$1" event_file="$2"
  local parsed base listed chain
  parsed=$(batch_constituents "$event_file") || {
    printf 'batch: cannot parse Mergify metadata from the PR body — whole-diff fallback\n'
    return 2
  }
  base=$(printf '%s\n' "$parsed" | sed -n 's/^base://p' | head -n 1)
  listed=$(printf '%s\n' "$parsed" | grep -v '^base:')
  if [ -z "$base" ] || [ -z "$listed" ]; then
    printf 'batch: metadata lists no constituents — whole-diff fallback\n'
    return 2
  fi
  head=$(resolve_batch_tip "$head" "$event_file")
  if [ "$head" != "$1" ]; then
    printf 'batch: checkout HEAD is the synthetic merge ref; walking from PR tip %s\n' "$head"
  fi
  if ! git merge-base --is-ancestor "$base" "$head" 2>/dev/null; then
    printf 'batch: checking base %s is not an ancestor of HEAD — whole-diff fallback\n' "$base"
    return 2
  fi
  chain=$(git log --first-parent --reverse --format='%H %s' "$base..$head" 2>/dev/null) || {
    printf 'batch: cannot walk the first-parent chain to %s — whole-diff fallback\n' "$base"
    return 2
  }
  local n_listed n_chain
  n_listed=$(printf '%s\n' "$listed" | grep -c .)
  n_chain=$(printf '%s\n' "$chain" | grep -c .)
  if [ "$n_listed" != "$n_chain" ]; then
    printf 'batch: metadata lists %s constituents but the merge chain has %s commits — whole-diff fallback\n' "$n_listed" "$n_chain"
    return 2
  fi
  local i=0 fail=0 line sha subject num want mf add files
  while IFS= read -r line; do
    i=$((i + 1))
    sha=${line%% *}
    subject=${line#* }
    case "$subject" in
      "Merge of #"*) num=${subject#"Merge of #"} ;;
      *)
        printf 'batch: chain commit %s is not a constituent merge ("%s") — whole-diff fallback\n' "${sha:0:8}" "$subject"
        return 2
        ;;
    esac
    case "$num" in
      *[!0-9]* | "")
        printf 'batch: chain commit %s has a non-numeric constituent ("%s") — whole-diff fallback\n' "${sha:0:8}" "$subject"
        return 2
        ;;
    esac
    want=$(printf '%s\n' "$listed" | sed -n "${i}p")
    if [ "$num" != "$want" ]; then
      printf 'batch: chain constituent #%s does not match listed #%s — whole-diff fallback\n' "$num" "$want"
      return 2
    fi
    mf=$(measure_diff "$sha^1" "$sha") || {
      printf 'batch: cannot measure #%s — whole-diff fallback\n' "$num"
      return 2
    }
    read -r add files <<<"$mf"
    if [ "$add" -le "$CAP_ADDITIONS" ] && [ "$files" -le "$CAP_FILES" ]; then
      printf '#%s: %s additions / %s files (cap %s / %s)\n' "$num" "$add" "$files" "$CAP_ADDITIONS" "$CAP_FILES"
    elif constituent_waived "$num"; then
      printf '#%s: waived by %s (#%s) (%s additions / %s files) — a reviewer must still check the reason comment\n' "$num" "$WAIVER_LABEL" "$num" "$add" "$files"
    else
      printf '#%s: %s additions / %s files exceeds cap %s / %s — split the PR, or write a waiver reason in a PR comment and ask for the %s label (then re-run gate-a)\n' "$num" "$add" "$files" "$CAP_ADDITIONS" "$CAP_FILES" "$WAIVER_LABEL"
      fail=1
    fi
  done <<<"$chain"
  [ "$fail" -eq 0 ]
}

# ---------------------------------------------------------------------------
# resolve_local_base — the local fallback (no event payload): the same base
# resolution the whitespace gate uses. Prints the base SHA, or nothing.
# ---------------------------------------------------------------------------
resolve_local_base() {
  local cand
  for cand in "${GIGAFAB_BASE_SHA:-}" "origin/main" "main"; do
    [ -n "$cand" ] || continue
    if git rev-parse --verify --quiet "$cand^{commit}" >/dev/null 2>&1; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Mutation self-proof. Fixtures are synthetic repos under $TMPDIR; the
# measurement core is run against them through check_diff, so a broken
# measurement cannot hide behind a green live verdict.
#
# mktemp is fail-closed here on purpose: a failed mktemp leaves $TMP empty,
# and an unchecked empty $TMP has already once turned "$TMP/bin/gh" into
# /bin/gh and overwritten the real gh binary (2026-11-07 gh-fake incident).
# $TMP is never used before this check passes.
# ---------------------------------------------------------------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/prdc.XXXXXX") || { bad "mktemp failed — refusing to run fixtures in an unknown directory"; printf '\n==> Total: %d | Pass: %d | Fail: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { bad "mktemp returned no usable directory — refusing to run"; printf '\n==> Total: %d | Pass: %d | Fail: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# mk_fixture <dir> <additions> — a repo whose feature branch adds exactly
# <additions> new lines across 2 files, on top of a 2-commit main.
mk_fixture() {
  local d="$1" n="$2" i per
  rm -rf "$d"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email gate@example.invalid
  git -C "$d" config user.name gate
  printf 'seed\n' > "$d/base.txt"
  git -C "$d" add -A && git -C "$d" commit -q -m "base 1"
  printf 'seed2\n' >> "$d/base.txt"
  git -C "$d" add -A && git -C "$d" commit -q -m "base 2"
  git -C "$d" checkout -q -b feature
  # Split the additions across two files so the file count is 2, not 1.
  per=$(( n / 2 ))
  for i in 1 2; do
    seq 1 "$per" | sed 's/^/added line /' > "$d/f$i.txt"
  done
  git -C "$d" add -A && git -C "$d" commit -q -m "feature adds $n lines"
  printf '%s' "$d"
}

# mk_payload <file> <base-sha> <labels-json-or-empty> — a synthetic
# pull_request event payload. Labels are a JSON array of label names.
mk_payload() {
  local f="$1" base="$2" labels="${3:-[]}"
  printf '{"pull_request": {"base": {"sha": "%s"}, "labels": %s}}' "$base" "$labels" > "$f"
}

# run_check <repo-dir> <payload-or-empty> — check_diff inside a fixture repo.
# The base is read from the payload itself (that is the path under test);
# only a payload without a base falls back to the fixture's main.
run_check() {
  local repo="$1" payload="$2" base=""
  if [ -n "$payload" ] && [ -f "$payload" ]; then
    base=$(jq -r '.pull_request.base.sha // empty' "$payload" 2>/dev/null) || base=""
  fi
  if [ -z "$base" ]; then
    base=$(git -C "$repo" rev-parse main)
  fi
  ( cd "$repo" && check_diff "$base" HEAD "$payload" ) >"$TMP/check.out" 2>&1
  local rc=$?
  sed 's/^/    /' "$TMP/check.out"
  return "$rc"
}

# mk_batch_fixture <dir> <n1> <n2> — a repo with a 2-commit main, two
# feature branches adding exactly <n1>/<n2> lines, and a queue branch that
# merges them as "Merge of #101" / "Merge of #102" on top of main.
mk_batch_fixture() {
  local d="$1" n1="$2" n2="$3" i per
  rm -rf "$d"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email gate@example.invalid
  git -C "$d" config user.name gate
  printf 'seed\n' > "$d/base.txt"
  git -C "$d" add -A && git -C "$d" commit -q -m "base 1"
  printf 'seed2\n' >> "$d/base.txt"
  git -C "$d" add -A && git -C "$d" commit -q -m "base 2"
  git -C "$d" checkout -q -b feat-a
  per=$(( (n1 + 1) / 2 ))
  seq 1 "$per" | sed 's/^/added line /' > "$d/a1.txt"
  per=$(( n1 / 2 ))
  seq 1 "$per" | sed 's/^/added line /' > "$d/a2.txt"
  git -C "$d" add -A && git -C "$d" commit -q -m "feat-a adds $n1 lines"
  git -C "$d" checkout -q main
  git -C "$d" checkout -q -b feat-b
  per=$(( (n2 + 1) / 2 ))
  seq 1 "$per" | sed 's/^/added line /' > "$d/b1.txt"
  per=$(( n2 / 2 ))
  seq 1 "$per" | sed 's/^/added line /' > "$d/b2.txt"
  git -C "$d" add -A && git -C "$d" commit -q -m "feat-b adds $n2 lines"
  git -C "$d" checkout -q main
  git -C "$d" checkout -q -b queue
  git -C "$d" merge -q --no-ff feat-a -m "Merge of #101"
  git -C "$d" merge -q --no-ff feat-b -m "Merge of #102"
  printf '%s' "$d"
}

# mk_batch_body <base-sha> <pr-numbers...> — a Mergify metadata block in
# the batch PR body, in the exact shape Mergify writes it.
mk_batch_body() {
  local base="$1"; shift
  local n
  printf '> [!NOTE]\n> **This is a merge queue draft opened by Mergify.**\n\n<details>\n<summary>Metadata for CI tooling</summary>\n\n```yaml\n---\nchecking_base_sha: %s\npull_requests:\n' "$base"
  for n in "$@"; do
    printf '  - number: %s\n    scopes: []\n' "$n"
  done
  printf 'scopes: []\n...\n\n```\n\n</details>\n'
}

# mk_batch_payload <file> <base-sha> <author> <head-ref> <body> <head-sha>
# — a synthetic pull_request event payload for a batch draft. The head SHA
# is the batch branch tip (the payload's .pull_request.head.sha).
mk_batch_payload() {
  local f="$1" base="$2" author="$3" ref="$4" body="$5" headsha="${6:-}"
  jq -n --arg base "$base" --arg author "$author" --arg ref "$ref" --arg body "$body" --arg headsha "$headsha" \
    '{pull_request: {base: {sha: $base}, user: {login: $author}, head: {ref: $ref, sha: $headsha}, body: $body, labels: []}}' > "$f"
}

# run_batch <repo-dir> <payload-or-empty> — check_batch inside a fixture
# repo, on its queue branch (HEAD). The base comes from the payload body.
run_batch() {
  local repo="$1" payload="$2"
  ( cd "$repo" && check_batch HEAD "$payload" ) >"$TMP/batch.out" 2>&1
  local rc=$?
  sed 's/^/    /' "$TMP/batch.out"
  return "$rc"
}

# --- M1: a 600-addition diff with no waiver must FAIL ---
echo ""
echo "-- M1: 600 additions, no waiver (expect FAIL) --"
R1=$(mk_fixture "$TMP/m1" 600)
P1="$TMP/m1-event.json"; mk_payload "$P1" "$(git -C "$R1" rev-parse main)"
if run_check "$R1" "$P1"; then
  bad "M1 passed a 600-addition PR — the cap does not bite"
else
  ok "M1 a 600-addition PR is red (rc=$?)"
fi

# --- M2: a 10-addition diff must PASS ---
echo ""
echo "-- M2: 10 additions (expect PASS) --"
R2=$(mk_fixture "$TMP/m2" 10)
P2="$TMP/m2-event.json"; mk_payload "$P2" "$(git -C "$R2" rev-parse main)"
if run_check "$R2" "$P2"; then
  ok "M2 a 10-addition PR is green"
else
  bad "M2 a 10-addition PR is red — the cap bites small work"
fi

# --- M3: a 600-addition diff WITH the waiver label must PASS (waived) ---
echo ""
echo "-- M3: 600 additions + ceiling-waived (expect PASS, waived) --"
R3=$(mk_fixture "$TMP/m3" 600)
P3="$TMP/m3-event.json"; mk_payload "$P3" "$(git -C "$R3" rev-parse main)" '[{"name": "ceiling-waived"}]'
if run_check "$R3" "$P3"; then
  out3=$(cat "$TMP/check.out")
  if grep -q 'waived by ceiling-waived' <<<"$out3"; then
    ok "M3 a waived 600-addition PR is green and says so"
  else
    bad "M3 passed but did not report the waiver — the waived state is invisible"
  fi
else
  bad "M3 a waived 600-addition PR is red — the waiver does not work"
fi

# --- M4: a payload with no pull_request must FAIL closed ---
echo ""
echo "-- M4: payload without pull_request (expect FAIL closed) --"
R4=$(mk_fixture "$TMP/m4" 10)
P4="$R4-event.json"; printf '{"action": "opened"}' > "$P4"
# M4 exercises the main-flow payload branch, not check_diff directly: the
# base cannot come from a payload with no pull_request.
if base4=$(jq -r '.pull_request.base.sha // empty' "$P4" 2>/dev/null) && [ -n "$base4" ]; then
  bad "M4 read a base SHA out of a payload with no pull_request — the fail-closed branch is dead"
else
  ok "M4 a payload without pull_request yields no base — fail-closed, not silent pass"
fi

# --- M5: an unreadable/missing payload file must FAIL closed ---
echo ""
echo "-- M5: GITHUB_EVENT_PATH points at a missing file (expect FAIL closed) --"
if [ -f "$TMP/does-not-exist.json" ]; then
  bad "M5 fixture setup broken — the missing file exists"
elif base5=$(jq -r '.pull_request.base.sha // empty' "$TMP/does-not-exist.json" 2>/dev/null) && [ -n "$base5" ]; then
  bad "M5 read a base SHA out of a missing payload file — the fail-closed branch is dead"
else
  ok "M5 a missing payload file yields no base — fail-closed, not silent pass"
fi

# --- M6: end-to-end positive control — the full main-flow path (payload
# base + labels) against a small fixture diff must PASS ---
echo ""
echo "-- M6: full payload path on a small diff (expect PASS) --"
R6=$(mk_fixture "$TMP/m6" 40)
P6="$TMP/m6-event.json"; mk_payload "$P6" "$(git -C "$R6" rev-parse main)"
if run_check "$R6" "$P6"; then
  out6=$(cat "$TMP/check.out")
  if grep -q '40 additions / 2 files' <<<"$out6"; then
    ok "M6 the measured numbers are the fixture numbers (40 additions / 2 files) — the measurement really measures"
  else
    bad "M6 passed but reported the wrong numbers — the measurement is not what it claims"
  fi
else
  bad "M6 the full payload path failed on a 40-addition diff"
fi

# --- M7: a two-constituent batch, 330 + 334 = 664 combined, each under
# cap — the F-1 shape — must PASS with per-constituent lines ---
echo ""
echo "-- M7: batch 330 + 334 = 664 combined, each under cap (expect PASS) --"
R7=$(mk_batch_fixture "$TMP/m7" 330 334)
B7=$(git -C "$R7" rev-parse main)
BODY7=$(mk_batch_body "$B7" 101 102)
P7="$TMP/m7-event.json"; mk_batch_payload "$P7" "$B7" "mergify[bot]" "mergify/merge-queue/abc123" "$BODY7" "$(git -C "$R7" rev-parse HEAD)"
if ( cd "$R7" && detect_batch "$P7" ); then
  ok "M7 the batch draft is detected (all three signals)"
else
  bad "M7 the batch draft was not detected — detection is broken"
fi
if run_batch "$R7" "$P7"; then
  out7=$(cat "$TMP/batch.out")
  if grep -q '#101: 330 additions / 2 files' <<<"$out7" && grep -q '#102: 334 additions / 2 files' <<<"$out7" && ! grep -q 'whole-diff fallback' <<<"$out7"; then
    ok "M7 a 664-combined batch passes with per-constituent lines (F-1 fixed)"
  else
    bad "M7 passed but did not report per-constituent lines — the batch path is not what it claims"
  fi
else
  bad "M7 a batch of two under-cap PRs is red — the F-1 failure is still there"
fi

# --- M8: a batch with one 600-addition constituent, no waiver, must FAIL
# and name the constituent ---
echo ""
echo "-- M8: batch with a 600-addition constituent, no waiver (expect FAIL naming #101) --"
R8=$(mk_batch_fixture "$TMP/m8" 600 10)
B8=$(git -C "$R8" rev-parse main)
BODY8=$(mk_batch_body "$B8" 101 102)
P8="$TMP/m8-event.json"; mk_batch_payload "$P8" "$B8" "mergify[bot]" "mergify/merge-queue/abc123" "$BODY8" "$(git -C "$R8" rev-parse HEAD)"
if run_batch "$R8" "$P8"; then
  bad "M8 a batch with a 600-addition unwaived constituent passed — the gate no longer bites"
else
  out8=$(cat "$TMP/batch.out")
  if grep -q '#101: 600 additions' <<<"$out8" && grep -q 'exceeds cap' <<<"$out8"; then
    ok "M8 the over-cap constituent is red and named (#101: 600 additions)"
  else
    bad "M8 failed but did not name the over-cap constituent — the verdict is not diagnosable"
  fi
fi

# --- M9: a 600-addition constituent WITH a stubbed waiver must PASS with
# a waived line ---
echo ""
echo "-- M9: batch, 600-addition constituent + stubbed waiver (expect PASS, waived) --"
R9=$(mk_batch_fixture "$TMP/m9" 600 10)
B9=$(git -C "$R9" rev-parse main)
BODY9=$(mk_batch_body "$B9" 101 102)
P9="$TMP/m9-event.json"; mk_batch_payload "$P9" "$B9" "mergify[bot]" "mergify/merge-queue/abc123" "$BODY9" "$(git -C "$R9" rev-parse HEAD)"
printf '101\n' > "$TMP/m9-waived.txt"
if GIGAFAB_WAIVER_FIXTURE="$TMP/m9-waived.txt" run_batch "$R9" "$P9"; then
  out9=$(cat "$TMP/batch.out")
  if grep -q 'waived by ceiling-waived (#101)' <<<"$out9"; then
    ok "M9 a waived 600-addition constituent is green and says so"
  else
    bad "M9 passed but did not report the waiver — the waived state is invisible"
  fi
else
  bad "M9 a waived 600-addition constituent is red — the waiver lookup does not work"
fi

# --- M10: a malformed batch (body lists 1 constituent, chain has 2
# merges) must fall back to whole-diff measurement, which then fails on
# the combined 610 ---
echo ""
echo "-- M10: malformed batch, body lists 1, chain has 2 (expect fallback to whole-diff, then FAIL) --"
R10=$(mk_batch_fixture "$TMP/m10" 600 10)
B10=$(git -C "$R10" rev-parse main)
BODY10=$(mk_batch_body "$B10" 101)
P10="$TMP/m10-event.json"; mk_batch_payload "$P10" "$B10" "mergify[bot]" "mergify/merge-queue/abc123" "$BODY10" "$(git -C "$R10" rev-parse HEAD)"
run_batch "$R10" "$P10"
rc10=$?
out10=$(cat "$TMP/batch.out")
if [ "$rc10" -eq 2 ] && grep -q 'whole-diff fallback' <<<"$out10"; then
  ok "M10 a malformed batch falls back to whole-diff measurement (rc=2, fallback line present)"
  P10b="$TMP/m10b-event.json"; mk_payload "$P10b" "$B10"
  if run_check "$R10" "$P10b"; then
    bad "M10 the whole-diff fallback passed a 610-addition combined diff — the fallback is a silent pass"
  else
    ok "M10 the fallback verdict is red on the combined 610 additions — today's behavior, preserved"
  fi
else
  bad "M10 a malformed batch did not fall back (rc=$rc10) — the detection is unsafe"
fi

# --- M11: a human PR with a mergify/merge-queue-shaped branch name but
# author not mergify[bot] must take the whole-diff path ---
echo ""
echo "-- M11: human author + batch-shaped branch (expect whole-diff path, FAIL on 610) --"
R11=$(mk_batch_fixture "$TMP/m11" 600 10)
B11=$(git -C "$R11" rev-parse main)
BODY11=$(mk_batch_body "$B11" 101 102)
P11="$TMP/m11-event.json"; mk_batch_payload "$P11" "$B11" "jajabong" "mergify/merge-queue/abc123" "$BODY11" "$(git -C "$R11" rev-parse HEAD)"
if ( cd "$R11" && detect_batch "$P11" ); then
  bad "M11 a human-authored PR was detected as a batch — a large PR could split itself into merge commits to pass"
else
  ok "M11 a human-authored PR is not detected as a batch (author signal holds)"
  P11b="$TMP/m11b-event.json"; mk_payload "$P11b" "$B11"
  if run_check "$R11" "$P11b"; then
    bad "M11 the whole-diff path passed a 610-addition combined diff"
  else
    ok "M11 the whole-diff path is red on the combined 610 additions"
  fi
fi

# --- M12: an over-cap constituent with no token and no fixture file must
# FAIL naming the constituent, with a loud waiver-unavailable notice —
# the API failure degrades per-constituent, never the whole card ---
echo ""
echo "-- M12: 600-addition constituent, no GH_TOKEN, no fixture (expect FAIL + lookup notice) --"
R12=$(mk_batch_fixture "$TMP/m12" 600 10)
B12=$(git -C "$R12" rev-parse main)
BODY12=$(mk_batch_body "$B12" 101 102)
P12="$TMP/m12-event.json"; mk_batch_payload "$P12" "$B12" "mergify[bot]" "mergify/merge-queue/abc123" "$BODY12" "$(git -C "$R12" rev-parse HEAD)"
if GH_TOKEN= GIGAFAB_WAIVER_FIXTURE= run_batch "$R12" "$P12"; then
  bad "M12 an over-cap constituent with no waiver lookup passed — the degraded mode is a silent pass"
else
  out12=$(cat "$TMP/batch.out")
  if grep -q 'waiver lookup unavailable for #101' <<<"$out12" && grep -q '#101: 600 additions' <<<"$out12"; then
    ok "M12 the degraded mode fails the constituent loudly (lookup notice + named verdict)"
  else
    bad "M12 failed but without the lookup notice or the named verdict — the degradation is not diagnosable"
  fi
fi

# --- M13: HEAD is the synthetic merge ref (the pull_request checkout
# shape: parents [base, tip], subject "Merge <tip> into <base>") — the
# walk must start at the payload head.sha, not at HEAD ---
echo ""
echo "-- M13: HEAD is the synthetic merge ref (expect PASS, walked from PR tip) --"
R13=$(mk_batch_fixture "$TMP/m13" 330 334)
B13=$(git -C "$R13" rev-parse main)
TIP13=$(git -C "$R13" rev-parse queue)
git -C "$R13" checkout -q main
git -C "$R13" merge -q --no-ff -m "Merge $TIP13 into $B13" "$TIP13"
BODY13=$(mk_batch_body "$B13" 101 102)
P13="$TMP/m13-event.json"; mk_batch_payload "$P13" "$B13" "mergify[bot]" "mergify/merge-queue/abc123" "$BODY13" "$TIP13"
if run_batch "$R13" "$P13"; then
  out13=$(cat "$TMP/batch.out")
  if grep -q '#101: 330 additions / 2 files' <<<"$out13" && grep -q '#102: 334 additions / 2 files' <<<"$out13" && grep -q 'synthetic merge ref' <<<"$out13"; then
    ok "M13 the synthetic merge ref is stepped through and the batch passes with per-constituent lines"
  else
    bad "M13 passed but did not report the synthetic-ref step or per-constituent lines"
  fi
else
  bad "M13 a batch checked out via the synthetic merge ref is red — the production checkout shape breaks the fix"
fi

echo ""
echo "-- non-vacuity accounting --"
# The fixtures above must have discriminated: M1 red, M2/M3/M6 green.
# (M4/M5 are fail-closed branches, asserted inline.)

# ---------------------------------------------------------------------------
# Live verdict: this checkout, right now.
# In CI the event payload is authoritative; locally the base falls back to
# merge-base resolution. A base that cannot be resolved anywhere is
# fail-closed, never a silent pass.
# ---------------------------------------------------------------------------
echo ""
echo "-- live verdict: this checkout --"
LIVE_RC=0
if [ -n "${GITHUB_EVENT_PATH:-}" ]; then
  if [ ! -f "$GITHUB_EVENT_PATH" ]; then
    bad "live: GITHUB_EVENT_PATH is set but unreadable ($GITHUB_EVENT_PATH) — fail-closed, no verdict"
    LIVE_RC=1
  else
    LIVE_BASE=$(jq -r '.pull_request.base.sha // empty' "$GITHUB_EVENT_PATH" 2>/dev/null) || LIVE_BASE=""
    if [ -z "$LIVE_BASE" ]; then
      bad "live: event payload carries no .pull_request.base.sha — fail-closed, no PR context"
      LIVE_RC=1
    else
      if detect_batch "$GITHUB_EVENT_PATH"; then
        printf 'batch: Mergify batch draft detected — per-constituent ceiling\n'
        LIVE_OUT=$(check_batch HEAD "$GITHUB_EVENT_PATH" 2>&1) && LIVE_RC=0 || LIVE_RC=$?
        if [ "$LIVE_RC" -eq 2 ]; then
          printf 'batch: falling back to whole-diff measurement\n'
          LIVE_OUT=$(check_diff "$LIVE_BASE" HEAD "$GITHUB_EVENT_PATH" 2>&1) && LIVE_RC=0 || LIVE_RC=$?
        fi
      else
        LIVE_OUT=$(check_diff "$LIVE_BASE" HEAD "$GITHUB_EVENT_PATH" 2>&1) && LIVE_RC=0 || LIVE_RC=$?
      fi
      printf '%s\n' "$LIVE_OUT" | sed 's/^/    /'
      if [ "$LIVE_RC" -eq 0 ]; then
        ok "live: this PR is within the ceiling (or waived)"
      elif [ "$LIVE_RC" -eq 2 ]; then
        bad "live: could not measure the diff (git failed) — fail-closed"
      else
        bad "live: this PR exceeds the ceiling without a waiver"
      fi
    fi
  fi
else
  LIVE_BASE=$(resolve_local_base) || LIVE_BASE=""
  if [ -z "$LIVE_BASE" ]; then
    bad "live: no event payload and no local base resolvable (tried GIGAFAB_BASE_SHA / origin/main / main) — fail-closed, nothing was certified"
  else
    LIVE_OUT=$(check_diff "$LIVE_BASE" HEAD "" 2>&1) && LIVE_RC=0 || LIVE_RC=$?
    printf '%s\n' "$LIVE_OUT" | sed 's/^/    /'
    if [ "$LIVE_RC" -eq 0 ]; then
      ok "live: this checkout is within the ceiling (base=${LIVE_BASE})"
    elif [ "$LIVE_RC" -eq 2 ]; then
      bad "live: could not measure the diff (git failed) — fail-closed"
    else
      bad "live: this checkout exceeds the ceiling without a waiver (base=${LIVE_BASE})"
    fi
  fi
fi

echo "---"
printf '==> Total: %d | Pass: %d | Fail: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
