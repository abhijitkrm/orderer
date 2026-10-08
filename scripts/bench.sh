#!/usr/bin/env bash
# bench.sh — spec/BENCH.md matrix for every present orderer impl, isolated
# and integrated.
#
# Corpora (ordergen, not committed): W4 (matcher's), W6 (64 symbols). Per
# language, three layers of the same matching core:
#
#   isolated    matcher-<lang>'s own matcherbench on W4: the core alone,
#               measured by the matcher project's protocol
#   embedded    orderer-<lang> --mode core on W4 and W6: the same core as
#               orderer links it (W6 untimed = the eff baseline)
#   integrated  orderer-<lang> --mode pipe on W6 at P=1..4 (3 informational):
#               journals off (rings + routing + egress only), then the gated
#               durable configuration (binary command journals, fsync/1024)
#
# eff is computed against the same impl's core W6 *untimed* throughput.
# A cross-language summary follows the per-language blocks.
# COOLDOWN=<s> sleeps between rows (fanless machines throttle).
#
#   scripts/bench.sh [--n N] [--append] [--only "rust go"]   # N = W6 run commands (default 10M)
#
# --append adds a dated block to docs/RESULTS.md. Never run in CI.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
. scripts/lib.sh
N=10000000; APPEND=0; ONLY=""
while [ $# -gt 0 ]; do
  case $1 in
    --n) N=$2; shift 2 ;;
    --append) APPEND=1; shift ;;
    --only) ONLY=$2; shift 2 ;;
    *) echo "unknown arg $1"; exit 2 ;;
  esac
done
mkdir -p bench
[ -f bench/w4.run.cmd.jsonl ] || ordergen --workload w4 --out bench/w4
[ -f "bench/w6-$N.run.cmd.jsonl" ] || ordergen --workload w6 --symbols 64 --n "$N" --out "bench/w6-$N"
MWORK=$(mktemp -d /tmp/orderer-bench-m.XXXXXX)
OUT=$(mktemp /tmp/orderer-bench.XXXXXX)
ROWS=$(mktemp -d /tmp/orderer-bench-rows.XXXXXX)
trap 'rm -rf "$MWORK" "$ROWS"' EXIT

# matcher's own row in orderer's columns, mode "isolated". matcher-rust, -go
# and -cpp print "| tag | ops | ops/s | mean | p50 | p90 | p99 | p99.9 | max |";
# matcher-java and -ts print "tag: N ops in T => R ops/s p50=… max=…" (no mean).
isolated_row() {
  awk -v l="$1" '
    /^\|/ { n = split($0, f, "|"); for (i = 1; i <= n; i++) gsub(/^ +| +$/, "", f[i])
             if (n >= 10) printf "| w4 | isolated | - | - | %s | %s |  | %s | %s | %s | %s | %s | %s | matcher-%s matcherbench |\n", f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], l; next }
    / ops\/s / { ops = $2; for (i = 1; i <= NF; i++) { if ($(i+1) == "ops/s") { r = $i; gsub(/,/, "", r) }
                  if (split($i, kv, "=") == 2) { v = kv[2]; sub(/ns$/, "", v); p[kv[1]] = v } }
                printf "| w4 | isolated | - | - | %s | %s |  |  | %s | %s | %s | %s | %s | matcher-%s matcherbench |\n", ops, r, p["p50"], p["p90"], p["p99"], p["p99.9"], p["max"], l }'
}

langs=$(orderer_present)
[ -n "$ONLY" ] && langs=$ONLY
for l in $langs; do
  build_orderer "$l"
  have_matcher=0
  if [ -d "$(matcher_dir "$l")" ]; then build_matcher "$l" && have_matcher=1; fi
  sha=$(git -C "$(orderer_dir "$l")" rev-parse --short HEAD 2>/dev/null || echo "?")
  {
    echo
    echo "### orderer-$l @ $(date +%Y-%m-%d) $sha"
    env=$(ot "$l" orderbench bench/w4 --mode core 2>&1 >/dev/null | sed -n 's/^env: //p')
    echo "env: $env; W6 = $N commands, 64 symbols"
    echo "| workload | mode | P | prod | ops | ops/s | eff | mean | p50 | p90 | p99 | p99.9 | max | config |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
    if [ "$have_matcher" = 1 ]; then
      { mbench "$l" bench/w4 --tag w4 2>/dev/null || true; } | isolated_row "$l" | tee "$ROWS/$l.isolated"
    fi
    ot "$l" orderbench bench/w4 --mode core --tag w4 2>/dev/null | tee "$ROWS/$l.core4"
    core=$(ot "$l" orderbench "bench/w6-$N" --mode core --tag w6 2>/dev/null)
    echo "$core" | tee "$ROWS/$l.core6"
    base=$(echo "$core" | sed -n 's/.*untimed=\([0-9]*\).*/\1/p')
    for j in off binary; do
      for P in 1 2 3 4; do
        sleep "${COOLDOWN:-0}"
        ot "$l" orderbench "bench/w6-$N" --mode pipe --partitions "$P" --journal "$j" --tag w6 --baseline "$base" 2>/dev/null \
          | tee "$ROWS/$l.$j.$P"
      done
    done
  } | tee -a "$OUT"
done

# ---- cross-language summary -------------------------------------------------------------
col() { if [ -s "$1" ]; then awk -F'|' -v c="$2" 'NR == 1 { gsub(/^ +| +$/, "", $c); print $c }' "$1"; else echo "—"; fi; }
untimed() { if [ -s "$1" ]; then sed -n 's/.*untimed=\([0-9]*\).*/\1/p' "$1" | head -1; else echo "—"; fi; }
m() { case $1 in ''|—) echo "—" ;; *) awk -v v="$1" 'BEGIN { printf "%.2fM", v / 1e6 }' ;; esac; }
us() { case $1 in ''|—) echo "—" ;; *) awk -v v="$1" 'BEGIN { printf "%.0f µs", v / 1e3 }' ;; esac; }
{
  echo
  echo "### Cross-language summary @ $(date +%Y-%m-%d) (ops/s; W6 = $N commands, 1 producer)"
  echo
  echo "| impl | matcher alone W4 | core W4 | core W6 untimed | pipe P=1 off | pipe P=4 off | pipe P=1 durable | pipe P=4 durable | eff(4) durable | p50 P=4 durable |"
  echo "|---|---|---|---|---|---|---|---|---|---|"
  for l in $langs; do
    echo "| $l | $(m "$(col "$ROWS/$l.isolated" 7)") | $(m "$(col "$ROWS/$l.core4" 7)") | $(m "$(untimed "$ROWS/$l.core6")")" \
      "| $(m "$(col "$ROWS/$l.off.1" 7)") | $(m "$(col "$ROWS/$l.off.4" 7)") | $(m "$(col "$ROWS/$l.binary.1" 7)")" \
      "| $(m "$(col "$ROWS/$l.binary.4" 7)") | $(col "$ROWS/$l.binary.4" 8) | $(us "$(col "$ROWS/$l.binary.4" 10)") |"
  done
} | tee -a "$OUT"
if [ "$APPEND" = 1 ]; then cat "$OUT" >> docs/RESULTS.md; echo "appended to docs/RESULTS.md"; fi
rm -f "$OUT"
