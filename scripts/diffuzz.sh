#!/usr/bin/env bash
# diffuzz.sh — differential fuzzing across implementations, on both axes.
#
# For each seed, ordergen emits an adversarial engine corpus. Then:
#   down:   every orderer impl at P=1 == every matcher impl's matcherfuzz
#   across: every orderer impl at P=2 and P=4 prints the identical listing
#           AND writes byte-identical per-partition journals (JSONL, binary)
#   both:   per-symbol streams at P>1 == the P=1 stream; seq dense
# orderer harnesses run CHECKED (book invariants after every command).
#
#   scripts/diffuzz.sh [seeds] [n-cmds]     # default: seeds 1..8, 20k cmds
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
. scripts/lib.sh
SEEDS=${1:-8}
N=${2:-20000}
WORK=$(mktemp -d /tmp/orderer-diffuzz.XXXXXX)
MWORK=$WORK/matcher
trap 'rm -rf "$WORK"' EXIT

echo "== building harnesses =="
OIMPLS=$(orderer_present); MIMPLS=$(matcher_present)
for l in $OIMPLS; do CHECKED=1 build_orderer "$l"; done
for l in $MIMPLS; do build_matcher "$l"; done
REF=${OIMPLS%% *}

fail=0
for seed in $(seq 1 "$SEEDS"); do
  c="$WORK/s$seed.cmd.jsonl"
  ordergen --seed "$seed" --n "$N" --symbols 8 --ids 512 > "$c"
  ot "$REF" ordererfuzz "$c" > "$WORK/ref.out" 2> "$WORK/ref.err" \
    || { echo "seed $seed: orderer-$REF crashed/invariant"; head -3 "$WORK/ref.err"; fail=1; continue; }
  ok=1
  for l in $OIMPLS; do
    [ "$l" = "$REF" ] || { ot "$l" ordererfuzz "$c" | cmp -s - "$WORK/ref.out" \
      || { echo "seed $seed: orderer-$l P=1 DIVERGES"; ok=0; }; }
  done
  for l in $MIMPLS; do
    mt "$l" matcherfuzz "$c" | cmp -s - "$WORK/ref.out" \
      || { echo "seed $seed: matcher-$l DIVERGES from orderer-$REF"; ok=0; }
  done
  seqcheck "$WORK/ref.out" || { echo "seed $seed: seq density violated"; ok=0; }
  for P in 2 4; do
    for fmt in jsonl binary; do
      flag=""; [ "$fmt" = binary ] && flag=--binary
      for l in $OIMPLS; do
        ot "$l" ordererfuzz "$c" --partitions "$P" --journal-dir "$WORK/j-$l-$P-$fmt" $flag \
          > "$WORK/$l-$P.out"
      done
      for l in $OIMPLS; do
        cmp -s "$WORK/$l-$P.out" "$WORK/$REF-$P.out" \
          || { echo "seed $seed: orderer-$l P=$P listing DIVERGES"; ok=0; }
        diff -r -q "$WORK/j-$l-$P-$fmt" "$WORK/j-$REF-$P-$fmt" >/dev/null \
          || { echo "seed $seed: orderer-$l P=$P $fmt journals DIVERGE"; ok=0; }
      done
    done
    cmp -s <(bysym "$WORK/$REF-$P.out") <(bysym "$WORK/ref.out") \
      || { echo "seed $seed: P=$P per-symbol streams differ from P=1"; ok=0; }
  done
  evs=$(wc -l < "$WORK/ref.out" | tr -d ' ')
  if [ "$ok" = 1 ]; then
    echo "seed $seed: $evs events — orderer($OIMPLS) × matcher($MIMPLS) identical; P=2,4 journals identical"
  else
    fail=1
  fi
done
[ "$fail" = 0 ] && echo "diffuzz: all seeds clean" || { echo "diffuzz: FAILURES"; exit 1; }
