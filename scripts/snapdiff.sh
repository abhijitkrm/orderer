#!/usr/bin/env bash
# snapdiff.sh — snapshot byte-parity: every orderer impl's ordersnap at
# P=1 and P=3 vs every matcher impl's matchersnap, on the same inputs.
#
#   scripts/snapdiff.sh [cmd.jsonl …]    # default: engine vector + a fuzz corpus
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
. scripts/lib.sh
WORK=$(mktemp -d /tmp/orderer-snapdiff.XXXXXX)
MWORK=$WORK/matcher
trap 'rm -rf "$WORK"' EXIT

OIMPLS=$(orderer_present); MIMPLS=$(matcher_present)
for l in $OIMPLS; do build_orderer "$l"; done
for l in $MIMPLS; do build_matcher "$l"; done
REF=${OIMPLS%% *}

inputs=("$@")
if [ ${#inputs[@]} -eq 0 ]; then
  ordergen --seed 7 --n 8000 > "$WORK/fuzz.cmd.jsonl"
  inputs=(vectors/matcher/engine/001_multisymbol.cmd.jsonl "$WORK/fuzz.cmd.jsonl")
fi
for f in "${inputs[@]}"; do
  echo "== $f"
  ot "$REF" ordersnap "$f" > "$WORK/ref.snap"
  for l in $OIMPLS; do
    for P in 1 3; do
      ot "$l" ordersnap "$f" --partitions "$P" | cmp -s - "$WORK/ref.snap" \
        || { echo "   orderer-$l P=$P: DIVERGED"; exit 1; }
    done
    echo "   orderer-$l P=1,3: byte-identical"
  done
  for l in $MIMPLS; do
    mt "$l" matchersnap "$f" | cmp -s - "$WORK/ref.snap" \
      || { echo "   matcher-$l: DIVERGED"; exit 1; }
    echo "   matcher-$l: byte-identical"
  done
done
echo "snapdiff: all implementations byte-identical"
