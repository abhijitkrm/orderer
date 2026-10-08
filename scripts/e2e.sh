#!/usr/bin/env bash
# e2e.sh — end-to-end journal/snapshot/recovery proof.
#
# Per orderer impl, at P=1 and P=3:
#   run cmds → full; run prefix --snap → prefix + snap; recover snap + tail
#   → recov; prefix + recov == full (P=1 byte-exact, P=3 per symbol).
#   Journal form: run with --journal-dir, recover from journals alone.
# Cross-restore matrix: every orderer AND matcher impl restores every
# orderer AND matcher impl's snapshot; all continuations identical.
# Adversarial: empty tail, seq-0 snapshot, truncated tail (must exit
# nonzero), torn binary journal (must exit nonzero).
#
#   scripts/e2e.sh [cmd.jsonl]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
. scripts/lib.sh
WORK=$(mktemp -d /tmp/orderer-e2e.XXXXXX)
MWORK=$WORK/matcher
trap 'rm -rf "$WORK"' EXIT

echo "== building harnesses =="
OIMPLS=$(orderer_present); MIMPLS=$(matcher_present)
for l in $OIMPLS; do build_orderer "$l"; done
for l in $MIMPLS; do build_matcher "$l"; done
REF=${OIMPLS%% *}

CMDS=${1:-$WORK/e2e.cmd.jsonl}
[ -n "${1:-}" ] || ordergen --seed 9 --n 6000 --symbols 8 --ids 256 > "$CMDS"
TOTAL=$(wc -l < "$CMDS" | tr -d ' ')
SPLIT=$((TOTAL / 2))
head -n "$SPLIT" "$CMDS" > "$WORK/prefix.cmd"
tail -n +$((SPLIT + 1)) "$CMDS" > "$WORK/tail.cmd"

# ---- per orderer impl -------------------------------------------------------
for l in $OIMPLS; do
  for P in 1 3; do
    ot "$l" orderrun "$CMDS" --partitions "$P" > "$WORK/$l-$P-full.evt"
    ot "$l" orderrun "$WORK/prefix.cmd" --partitions "$P" --snap "$WORK/$l-$P.snap" > "$WORK/$l-$P-prefix.evt"
    ot "$l" orderrecover "$WORK/$l-$P.snap" "$WORK/tail.cmd" --partitions "$P" > "$WORK/$l-$P-recov.evt"
    cat "$WORK/$l-$P-prefix.evt" "$WORK/$l-$P-recov.evt" > "$WORK/$l-$P-joined.evt"
    if [ "$P" = 1 ]; then
      cmp -s "$WORK/$l-$P-joined.evt" "$WORK/$l-$P-full.evt" \
        || { echo "orderer-$l P=1: E2E DIVERGED"; exit 1; }
    else
      cmp -s <(bysym "$WORK/$l-$P-joined.evt") <(bysym "$WORK/$l-$P-full.evt") \
        || { echo "orderer-$l P=$P: E2E DIVERGED (per symbol)"; exit 1; }
    fi
    # journal form: recover the whole run from journals alone
    ot "$l" orderrun "$CMDS" --partitions "$P" --journal-dir "$WORK/$l-$P-jd" --binary > /dev/null
    ot "$l" orderrecover --journal-dir "$WORK/$l-$P-jd" --binary --partitions "$P" > "$WORK/$l-$P-jr.evt"
    cmp -s <(bysym "$WORK/$l-$P-jr.evt") <(bysym "$WORK/$l-$P-full.evt") \
      || { echo "orderer-$l P=$P: journal-form recovery DIVERGED"; exit 1; }
    cmp -s "$WORK/$l-$P.snap" "$WORK/$REF-1.snap" \
      || { echo "orderer-$l P=$P: snapshot differs from orderer-$REF P=1"; exit 1; }
  done
  echo "orderer-$l: e2e identical at P=1 and P=3 (snapshot, tail, journal form)"
done

# ---- cross-restore matrix -----------------------------------------------------
for l in $MIMPLS; do mt "$l" matcherrun "$WORK/prefix.cmd" --snap "$WORK/m-$l.snap" > /dev/null; done
ot "$REF" orderrecover "$WORK/$REF-1.snap" "$WORK/tail.cmd" > "$WORK/ref-tail.evt"
SNAPS=""; for l in $OIMPLS; do SNAPS="$SNAPS $WORK/$l-1.snap $WORK/$l-3.snap"; done
for l in $MIMPLS; do SNAPS="$SNAPS $WORK/m-$l.snap"; done
n=0
for s in $SNAPS; do
  for l in $OIMPLS; do
    ot "$l" orderrecover "$s" "$WORK/tail.cmd" | cmp -s - "$WORK/ref-tail.evt" \
      || { echo "cross-restore $(basename "$s") → orderer-$l DIVERGED"; exit 1; }
    n=$((n + 1))
  done
  for l in $MIMPLS; do
    mt "$l" matcherrecover "$s" "$WORK/tail.cmd" | cmp -s - "$WORK/ref-tail.evt" \
      || { echo "cross-restore $(basename "$s") → matcher-$l DIVERGED"; exit 1; }
    n=$((n + 1))
  done
done
echo "cross-restore: $n combinations byte-identical"

# ---- adversarial ----------------------------------------------------------------
: > "$WORK/empty.cmd"
[ -z "$(ot "$REF" orderrecover "$WORK/$REF-1.snap" "$WORK/empty.cmd")" ] \
  && echo "empty tail: clean" || { echo "empty tail FAILED"; exit 1; }
head -1 "$CMDS" > "$WORK/only-header.cmd"
ot "$REF" orderrun "$WORK/only-header.cmd" --snap "$WORK/zero.snap" > /dev/null
grep -v '"format"' "$CMDS" > "$WORK/all.cmd"
ot "$REF" orderrecover "$WORK/zero.snap" "$WORK/all.cmd" | cmp -s - "$WORK/$REF-1-full.evt" \
  && echo "seq-0 snapshot + full replay: identical" || { echo "seq-0 replay FAILED"; exit 1; }
{ head -5 "$WORK/tail.cmd"; head -1 "$WORK/tail.cmd" | cut -c1-30; } > "$WORK/trunc.cmd"
if ot "$REF" orderrecover "$WORK/$REF-1.snap" "$WORK/trunc.cmd" > /dev/null 2>&1; then
  echo "truncated tail: NOT DETECTED"; exit 1
else echo "truncated tail: detected (nonzero exit)"; fi
j="$WORK/$REF-3-jd/cmd-1.bin"
head -c $(( $(wc -c < "$j") - 7 )) "$j" > "$WORK/torn" && cp "$WORK/torn" "$j"
if ot "$REF" orderrecover --journal-dir "$WORK/$REF-3-jd" --binary --partitions 3 > /dev/null 2>&1; then
  echo "torn journal: NOT DETECTED"; exit 1
else echo "torn journal: detected (nonzero exit)"; fi
echo "e2e: all checks passed"
