#!/usr/bin/env bash
# exhaustive.sh — bounded exhaustive equivalence on the real shipped code.
#
# ordergen --exhaustive D emits EVERY length-D sequence over fuzzgen's
# 8-command alphabet (two alternating symbols). Every orderer impl (P=1 and
# P=2) and every matcher impl runs every sequence; all streams must be
# identical (P=2 per symbol). Within the bounded domain this is a proof,
# not sampling.
#
#   scripts/exhaustive.sh [depth]     # default 3 → 512 sequences
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
. scripts/lib.sh
DEPTH=${1:-3}
WORK=$(mktemp -d /tmp/orderer-exhaustive.XXXXXX)
MWORK=$WORK/matcher
trap 'rm -rf "$WORK"' EXIT

echo "== building harnesses =="
OIMPLS=$(orderer_present); MIMPLS=$(matcher_present)
for l in $OIMPLS; do CHECKED=1 build_orderer "$l"; done
for l in $MIMPLS; do build_matcher "$l"; done
REF=${OIMPLS%% *}

ordergen --exhaustive "$DEPTH" --out "$WORK/seqs" 2>/dev/null
fail=0; checked=0
for f in "$WORK"/seqs/*.cmd.jsonl; do
  ot "$REF" ordererfuzz "$f" > "$WORK/ref.out" 2>"$WORK/ref.err" \
    || { echo "$(basename "$f"): orderer-$REF crashed/invariant"; head -3 "$WORK/ref.err"; fail=1; continue; }
  for l in $OIMPLS; do
    [ "$l" = "$REF" ] || ot "$l" ordererfuzz "$f" | cmp -s - "$WORK/ref.out" \
      || { echo "$(basename "$f"): orderer-$l DIVERGES"; fail=1; }
    ot "$l" ordererfuzz "$f" --partitions 2 > "$WORK/p2.out"
    cmp -s <(bysym "$WORK/p2.out") <(bysym "$WORK/ref.out") \
      || { echo "$(basename "$f"): orderer-$l P=2 DIVERGES per symbol"; fail=1; }
  done
  for l in $MIMPLS; do
    mt "$l" matcherfuzz "$f" | cmp -s - "$WORK/ref.out" \
      || { echo "$(basename "$f"): matcher-$l DIVERGES"; fail=1; }
  done
  checked=$((checked + 1))
done
if [ "$fail" = 0 ]; then
  echo "exhaustive: $checked sequences (depth $DEPTH) — orderer($OIMPLS) P=1,2 × matcher($MIMPLS) identical ✓"
else
  echo "exhaustive: FAILURES"; exit 1
fi
