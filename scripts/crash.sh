#!/usr/bin/env bash
# crash.sh — durability under real crashes (JOURNAL.md 1.2 §5.1, PIPELINE.md §5).
#
# For every present orderer implementation, ROUNDS times: run
# `orderrun --durable` (fsync every 64 records, acks reported on stderr) on a
# large corpus, SIGKILL it at a random moment, then
#
#   1. `orderrecover --repair` must succeed (exit 0);
#   2. every command reported `acked` must be in the recovered journal;
#   3. each partition's recovered commands must be exactly the commands
#      routed to it, in order, with no gaps: a prefix of its stream (or,
#      after a checkpoint, the contiguous run after the cut);
#   4. without a checkpoint, each symbol's recovered events must be a
#      prefix of the same symbol's events in an uninterrupted run.
#
# Rounds alternate JSONL / binary journals; every third round also takes
# checkpoints, so some kills land mid-rotation.
#
#   scripts/crash.sh [rounds] [n-cmds]     # default 6 rounds, 300k commands
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
. scripts/lib.sh
ROUNDS=${1:-6}; N=${2:-300000}; P=2
W=$(mktemp -d /tmp/orderer-crash.XXXXXX)
trap 'rm -rf "$W"' EXIT

echo "== building harnesses =="
IMPLS=$(orderer_present)
for l in $IMPLS; do build_orderer "$l"; done
ordergen --seed 77 --n "$N" --symbols 8 --ids 4096 > "$W/corpus.jsonl"
ref=$(echo $IMPLS | awk '{print $1}')
ot "$ref" ordererfuzz "$W/corpus.jsonl" > "$W/full.evt"

check() { # dir format log rec.evt checkpointed
  python3 - "$W/corpus.jsonl" "$1" "$2" "$3" "$4" "$5" "$W/full.evt" "$P" <<'EOF'
import json, os, re, struct, sys
corpus, d, fmt, log, rec, ckpt, full, P = sys.argv[1:9]
P = int(P)
def part(s):
    h = (s * 0x9E3779B97F4A7C15) % 2**64
    return ((h >> 32) * P) >> 32
# the stream each partition was sent: (iseq, symbol, canonical command)
lines = open(corpus).read().splitlines()[1:]
stream = {p: [] for p in range(P)}
def canon(l):
    o = json.loads(l); o.pop("iseq", None); return json.dumps(o, sort_keys=True)
for i, l in enumerate(lines):
    s = json.loads(l).get("symbol", 0)
    stream[part(s)].append((i + 1, s, canon(l)))
# what the journals hold (all segments, start order)
ext = ".bin" if fmt == "binary" else ".journal"
segs = {}
for f in os.listdir(d):
    m = re.fullmatch(r"cmd-(\d+)(?:\.(\d+))?" + re.escape(ext), f)
    if m:
        segs.setdefault(int(m.group(1)), []).append((int(m.group(2) or 0), f))
SIDE = ["bid", "ask"]; OT = ["limit", "market"]; TIF = ["gtc", "ioc", "fok", "post_only"]
def records(path):
    if fmt == "jsonl":
        out = []
        for l in open(path).read().splitlines()[1:]:
            out.append((json.loads(l)["iseq"], json.loads(l)["symbol"], canon(l)))
        return out
    b = open(path, "rb").read()
    size = struct.unpack_from("<I", b, 16)[0]
    out = []
    for at in range(64, len(b), size):
        iseq, sym, k, side, ot, tif, oid, price, qty = struct.unpack_from("<QIBBBBQqQ", b, at)
        if k == 1:
            o = {"cmd": "new", "symbol": sym, "order_id": oid, "side": SIDE[side], "otype": OT[ot], "price": price, "qty": qty, "tif": TIF[tif]}
        elif k == 2:
            o = {"cmd": "cancel", "symbol": sym, "order_id": oid}
        else:
            o = {"cmd": "replace", "symbol": sym, "order_id": oid, "price": price, "qty": qty}
        out.append((iseq, sym, json.dumps(o, sort_keys=True)))
    return out
cut = 0
for f in os.listdir(d):
    m = re.fullmatch(r"checkpoint-(\d+)\.snap", f)
    if m and os.path.exists(os.path.join(d, f + ".meta")):
        cut = max(cut, int(m.group(1)))
errs = []
recovered = {}
for p in range(P):
    got = []
    for _, f in sorted(segs.get(p, [])):
        got += records(os.path.join(d, f))
    got = [r for r in got if r[0] > cut]
    want = [r for r in stream[p] if r[0] > cut][: len(got)]
    if got != want:
        errs.append(f"partition {p}: recovered commands are not the contiguous run after the cut ({len(got)} records)")
    recovered[p] = got[-1][0] if got else cut
# every ack survived
acked = {}
for l in open(log).read().split("\n")[:-1]:   # the last line may be torn by the kill
    m = re.fullmatch(r"acked (\d+) (\d+)", l)
    if m:
        p, i = int(m.group(1)), int(m.group(2)); acked[p] = max(acked.get(p, 0), i)
for p, i in acked.items():
    if i > recovered[p]:
        errs.append(f"partition {p}: acked iseq {i} but recovered only up to {recovered[p]}")
# events: per-symbol prefix of the uninterrupted run (no checkpoint)
if ckpt == "0":
    def bysym(path):
        out = {}
        for l in open(path).read().splitlines():
            s = json.loads(l)["symbol"]; out.setdefault(s, []).append(l)
        return out
    r, f = bysym(rec), bysym(full)
    for s, evs in r.items():
        if evs != f.get(s, [])[: len(evs)]:
            errs.append(f"symbol {s}: recovered events are not a prefix of the uninterrupted run")
print("ERR " + "; ".join(errs) if errs else "ok")
for p in range(P):
    print(f"  p{p}: recovered through iseq {recovered[p]}, acked through {acked.get(p, 0)}", file=sys.stderr)
EOF
}

fail=0
for l in $IMPLS; do
  for r in $(seq 1 "$ROUNDS"); do
    fmt=jsonl; flag=""; [ $((r % 2)) = 0 ] && { fmt=binary; flag=--binary; }
    ck=""; ckpt=0; [ $((r % 3)) = 0 ] && { ck="--checkpoint-every $((N / 7))"; ckpt=1; }
    d="$W/$l-$r"; mkdir -p "$d"
    # a random kill time: 100–1500 ms
    delay=$(awk -v s="$RANDOM" 'BEGIN { srand(s); printf "%.2f", 0.1 + rand() * 1.4 }')
    "$(orderer_dir "$l")/harness/bin/orderrun" "$W/corpus.jsonl" --partitions $P --journal-dir "$d" $flag --durable $ck \
      > /dev/null 2> "$d.acks" &
    pid=$!
    sleep "$delay"
    if kill -9 "$pid" 2>/dev/null; then how="killed at ${delay}s"; else how="finished before ${delay}s"; fi
    wait "$pid" 2>/dev/null || true
    # a kill can land before the journals exist; that round has nothing to check
    if ! ls "$d"/cmd-* > /dev/null 2>&1; then echo "$l round $r ($fmt): $how before any journal — skipped"; continue; fi
    if ! ot "$l" orderrecover --journal-dir "$d" $flag --repair --partitions $P > "$d.rec" 2> "$d.repair"; then
      echo "FAIL $l round $r ($fmt, $how): orderrecover --repair failed: $(head -2 "$d.repair")"; fail=1; continue
    fi
    res=$(check "$d" $fmt "$d.acks" "$d.rec" $ckpt 2> "$d.detail")
    acks=$(grep -c '^acked' "$d.acks" || true)
    rep=$(grep -c '^repaired' "$d.repair" || true)
    if [ "${res%% *}" = ok ]; then
      echo "ok   $l round $r ($fmt$([ $ckpt = 1 ] && echo ", checkpoints"), $how): $acks ack lines, $rep file(s) repaired, $(tr '\n' ';' < "$d.detail")"
    else
      echo "FAIL $l round $r ($fmt, $how): ${res#ERR }"; fail=1
    fi
  done
done
[ $fail = 0 ] && echo "crash: every acked command survived; every partition recovered a clean prefix" || { echo "crash: FAILURES"; exit 1; }
