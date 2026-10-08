#!/usr/bin/env bash
# bench.sh — spec/BENCH.md matrix for every present orderer impl.
#
# Corpora (ordergen, not committed): W4 (matcher's), W6 (64 symbols). Rows:
# core W4 + W6, then pipeline W6 at P=1,2,3,4 (3 informational) with the gated journal
# configuration (binary command journals, fsync every 1024). eff is
# computed against the same impl's core W6 *untimed* throughput.
# COOLDOWN=<s> sleeps between rows (fanless machines throttle).
#
#   scripts/bench.sh [--n N] [--append]     # N = W6 run commands (default 10M)
#
# --append adds a dated block to docs/RESULTS.md. Never run in CI.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
. scripts/lib.sh
N=10000000; APPEND=0
while [ $# -gt 0 ]; do
  case $1 in --n) N=$2; shift 2 ;; --append) APPEND=1; shift ;; *) echo "unknown arg $1"; exit 2 ;; esac
done
mkdir -p bench
[ -f bench/w4.run.cmd.jsonl ] || ordergen --workload w4 --out bench/w4
[ -f "bench/w6-$N.run.cmd.jsonl" ] || ordergen --workload w6 --symbols 64 --n "$N" --out "bench/w6-$N"

OUT=$(mktemp /tmp/orderer-bench.XXXXXX)
for l in $(orderer_present); do
  build_orderer "$l"
  sha=$(git -C "$(orderer_dir "$l")" rev-parse --short HEAD 2>/dev/null || echo "?")
  {
    echo
    echo "### orderer-$l @ $(date +%Y-%m-%d) $sha"
    env=$(ot "$l" orderbench bench/w4 --mode core 2>&1 >/dev/null | sed -n 's/^env: //p')
    echo "env: $env / journal binary fsync 1024"
    echo "| workload | mode | P | prod | ops | ops/s | eff | mean | p50 | p90 | p99 | p99.9 | max | config |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
    ot "$l" orderbench bench/w4 --mode core --tag w4 2>/dev/null
    core=$(ot "$l" orderbench "bench/w6-$N" --mode core --tag w6 2>/dev/null)
    echo "$core"
    base=$(echo "$core" | sed -n 's/.*untimed=\([0-9]*\).*/\1/p')
    for P in 1 2 3 4; do
      sleep "${COOLDOWN:-0}"
      ot "$l" orderbench "bench/w6-$N" --mode pipe --partitions "$P" --tag w6 --baseline "$base" 2>/dev/null
    done
  } | tee -a "$OUT"
done
if [ "$APPEND" = 1 ]; then cat "$OUT" >> docs/RESULTS.md; echo "appended to docs/RESULTS.md"; fi
rm -f "$OUT"
