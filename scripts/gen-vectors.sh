#!/usr/bin/env bash
# gen-vectors.sh — (re)generate orderer's vectors from the reference
# implementation (orderer-rust), then rebuild vectors/manifest.json.
#
# Outputs are AUDITED before commit (CONTRIBUTING.md): every expected file
# here must also follow from the spec. Inputs that are not derived from a
# tool (vectors/regress/*.cmd.jsonl) are committed as-is.
#
#   scripts/gen-vectors.sh            # ORDERER_RUST_DIR defaults to ../orderer-rust
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
RUST=${ORDERER_RUST_DIR:-$ROOT/../orderer-rust}
V=$ROOT/vectors

echo "== building orderer-rust harnesses + ordergen =="
(cd "$RUST" && cargo build --release --quiet --bin orderrun --bin ordererfuzz --bin orderrecover --bin ordersnap)
cargo build --release --quiet --manifest-path tools/ordergen/Cargo.toml
BIN=$RUST/target/release
OG=tools/ordergen/target/release/ordergen

# ---- routing: hash function reference table + a partition-table case --------
mkdir -p "$V/routing"
python3 - "$V/routing" <<'EOF'
import sys, os
out = sys.argv[1]
M = 2**64
def part(s, p):
    h = (s * 0x9E3779B97F4A7C15) % M
    return ((h >> 32) * p) >> 32
syms = list(range(0, 64)) + [255, 256, 4095, 4096, 65535, 65536, 2**31 - 1, 2**31, 2**32 - 1]
with open(os.path.join(out, "hash.jsonl"), "w") as f:
    f.write('{"format":"orderer-routing-vectors/1","kind":"hash"}\n')
    for p in [1, 2, 3, 4, 5, 7, 8, 1024]:
        for s in syms:
            f.write('{"symbol":%d,"partitions":%d,"partition":%d}\n' % (s, p, part(s, p)))
table = {10: 3, 20: 3, 4096: 0, 2**32 - 1: 1}
with open(os.path.join(out, "table.map.jsonl"), "w") as f:
    f.write('{"format":"orderer-partition-map/1","partitions":4}\n')
    for s, p in table.items():
        f.write('{"symbol":%d,"partition":%d}\n' % (s, p))
with open(os.path.join(out, "table.expect.jsonl"), "w") as f:
    f.write('{"format":"orderer-routing-vectors/1","kind":"table","map":"table.map.jsonl"}\n')
    for s in sorted(set(list(range(0, 24)) + list(table))):
        f.write('{"symbol":%d,"partitions":4,"partition":%d}\n' % (s, table.get(s, part(s, 4))))
EOF

# ---- regress: matcher-format golden vectors (expected from the reference) ----
for cmd in "$V"/regress/*.cmd.jsonl; do
  name=$(basename "$cmd" .cmd.jsonl)
  short=$(head -1 "$cmd" | sed 's/.*"name":"\([^"]*\)".*/\1/')
  { printf '{"format":"matcher-vector/1","name":"%s"}\n' "$short"; "$BIN/ordererfuzz" "$cmd"; } \
    > "$V/regress/$name.evt.jsonl"
done

# ---- pipeline: per-partition listings + journals in both encodings ----------
mkdir -p "$V/pipeline"
cp "$V/matcher/engine/001_multisymbol.cmd.jsonl" "$V/pipeline/multisymbol.cmd.jsonl"
"$OG" --seed 11 --n 3000 --symbols 8 --ids 64 > "$V/pipeline/fuzz_s11.cmd.jsonl"
for input in multisymbol fuzz_s11; do
  for P in 1 2 4; do
    d="$V/pipeline/$input/P$P"
    rm -rf "$d"; mkdir -p "$d"
    "$BIN/orderrun" "$V/pipeline/$input.cmd.jsonl" --partitions "$P" --journal-dir "$d/jsonl" > "$d/listing.evt"
    "$BIN/orderrun" "$V/pipeline/$input.cmd.jsonl" --partitions "$P" --journal-dir "$d/binary" --binary > "$d/listing.binary.evt"
    cmp -s "$d/listing.evt" "$d/listing.binary.evt" || { echo "listing depends on journal format!"; exit 1; }
    rm "$d/listing.binary.evt"
  done
done

# ---- recovery: snapshot + tail → continuation; cross-P restore --------------
d="$V/recovery/fuzz_s11"
rm -rf "$d"; mkdir -p "$d"
src="$V/pipeline/fuzz_s11.cmd.jsonl"
total=$(wc -l < "$src" | tr -d ' ')
split=$((total / 2))
head -n "$split" "$src" > "$d/prefix.cmd.jsonl"
tail -n +$((split + 1)) "$src" > "$d/tail.cmd.jsonl"
"$BIN/orderrun" "$d/prefix.cmd.jsonl" --partitions 3 --snap "$d/prefix.snap" > /dev/null
for P in 1 3; do
  "$BIN/orderrecover" "$d/prefix.snap" "$d/tail.cmd.jsonl" --partitions "$P" > "$d/recov.P$P.evt"
done

# ---- checkpoint (1.2): segments rotated at deterministic cuts -----------------
for input in multisymbol fuzz_s11; do
  src="$V/pipeline/$input.cmd.jsonl"
  n=$(($(wc -l < "$src" | tr -d ' ') - 1))
  K=$((n * 2 / 5))
  d="$V/checkpoint/$input"
  rm -rf "$d"; mkdir -p "$d"
  echo "$K" > "$d/K"
  for enc in jsonl binary; do
    flag=""; [ $enc = binary ] && flag=--binary
    "$BIN/orderrun" "$src" --partitions 2 --journal-dir "$d/$enc" $flag --checkpoint-every "$K" > "$d/listing.$enc.evt"
    cmp -s "$d/listing.$enc.evt" "$V/pipeline/$input/P2/listing.evt" || { echo "checkpoints changed the listing!"; exit 1; }
    rm "$d/listing.$enc.evt"
    "$BIN/orderrecover" --journal-dir "$d/$enc" $flag --partitions 2 > "$d/recov.$enc.evt"
  done
  cmp -s "$d/recov.jsonl.evt" "$d/recov.binary.evt" || { echo "recovery depends on journal format!"; exit 1; }
  mv "$d/recov.jsonl.evt" "$d/recov.evt"; rm "$d/recov.binary.evt"
done

# ---- repair (1.2): torn tails a crash can leave -----------------------------
# Inputs: fuzz_s11's P=2 journals with partition 0's last record cut short
# and (binary) partition 1's last record zeroed. Expected: what
# `orderrecover --repair` prints, and the repaired files.
d="$V/repair/fuzz_s11"
rm -rf "$d"; mkdir -p "$d"
for enc in jsonl binary; do
  flag=""; ext=journal; [ $enc = binary ] && { flag=--binary; ext=bin; }
  cp -R "$V/pipeline/fuzz_s11/P2/$enc" "$d/$enc.torn"
  f0="$d/$enc.torn/cmd-0.$ext"
  python3 - "$f0" <<'PY'
import sys
p = sys.argv[1]; b = open(p, 'rb').read(); open(p, 'wb').write(b[:-5])
PY
  if [ $enc = binary ]; then
    python3 - "$d/$enc.torn/cmd-1.bin" <<'PY'
import sys
p = sys.argv[1]; b = bytearray(open(p, 'rb').read()); b[-48:] = bytes(48); open(p, 'wb').write(bytes(b))
PY
  fi
  cp -R "$d/$enc.torn" "$d/$enc.repaired"
  "$BIN/orderrecover" --journal-dir "$d/$enc.repaired" $flag --repair --partitions 2 > "$d/recov.$enc.evt" 2>/dev/null
done

# ---- repair (1.3): a segment created at a checkpoint without its header -----
# Inputs: checkpoint/fuzz_s11's journal dirs plus the next checkpoint's
# segments, torn before their headers reached the file: partition 0's
# command segment holds 10 bytes of header, partition 1's is empty, and
# partition 0's event segment is zero-filled. Expected: --repair deletes
# exactly those, leaving the checkpoint dir as it was.
d="$V/repair/checkpoint_fuzz_s11"
rm -rf "$d"; mkdir -p "$d"
# the next checkpoint's cut: the last one's plus K
cut=$(ls "$V/checkpoint/fuzz_s11/jsonl" | sed -n 's/^checkpoint-\([0-9]*\)\.snap$/\1/p' | sort -n | tail -1)
M=$(( cut + $(cat "$V/checkpoint/fuzz_s11/K") ))
for enc in jsonl binary; do
  ext=journal; [ $enc = binary ] && ext=bin
  src="$V/checkpoint/fuzz_s11/$enc"
  cp -R "$src" "$d/$enc.torn"
  cp -R "$src" "$d/$enc.repaired"
  head -c 10 "$(ls "$src"/cmd-0.*.$ext | head -1)" > "$d/$enc.torn/cmd-0.$M.$ext"
  : > "$d/$enc.torn/cmd-1.$M.$ext"
  n=20; [ $enc = binary ] && n=64
  head -c $n /dev/zero > "$d/$enc.torn/evt-0.$M.$ext"
  cp "$V/checkpoint/fuzz_s11/recov.evt" "$d/recov.$enc.evt"
done

# ---- repair (1.3): a torn segment behind a header-only one ----------------
# A writer may create the next checkpoint's segment (header only) while the
# previous segment's end is still being written. Inputs: checkpoint/
# fuzz_s11 plus header-only next segments for partition 0, whose 2400
# segments are torn (cmd: last record cut short; JSONL evt: last line cut).
# Expected (computed here): the torn segments repaired, the header-only
# segments kept.
d="$V/repair/rotation_fuzz_s11"
rm -rf "$d"; mkdir -p "$d"
src0="$V/checkpoint/fuzz_s11"
cut=$(ls "$src0/jsonl" | sed -n 's/^checkpoint-\([0-9]*\)\.snap$/\1/p' | sort -n | tail -1)
M=$(( cut + $(cat "$src0/K") ))
for enc in jsonl binary; do
  flag=""; [ $enc = binary ] && flag=--binary
  cp -R "$src0/$enc" "$d/$enc.torn"; cp -R "$src0/$enc" "$d/$enc.repaired"
  python3 - "$d/$enc.torn" "$d/$enc.repaired" $enc "$cut" "$M" <<'PY'
import sys
torn, rep, enc, cut, M = sys.argv[1:6]
ext = 'bin' if enc == 'binary' else 'journal'
def rd(p): return open(p, 'rb').read()
def wr(p, b): open(p, 'wb').write(b)
for k in ('cmd', 'evt'):
    seg = rd(f'{torn}/{k}-0.{cut}.{ext}')
    hdr = seg[:64] if enc == 'binary' else seg[:seg.index(b'\n') + 1]
    for dd in (torn, rep):
        wr(f'{dd}/{k}-0.{M}.{ext}', hdr)
    if enc == 'binary':
        size = 48 if k == 'cmd' else 56
        good = seg[:len(seg) - size]          # the last record is the torn one
        wr(f'{torn}/{k}-0.{cut}.{ext}', good + seg[len(good):len(good) + size // 2])
    else:
        last = seg.rstrip(b'\n').rfind(b'\n') + 1
        good = seg[:last]
        wr(f'{torn}/{k}-0.{cut}.{ext}', good + seg[last:last + 9])
    wr(f'{rep}/{k}-0.{cut}.{ext}', good)
PY
  "$BIN/orderrecover" --journal-dir "$d/$enc.repaired" $flag --partitions 2 > "$d/recov.$enc.evt"
done

# ---- repair (1.3): zero-filled tails --------------------------------------
# An interrupted write can leave a file extended by zeros. Inputs, from
# fuzz_s11's P=2 journals. Binary: cmd-0 gains 3 zero records and a
# partial zero record; evt-1's last 4 records are zeroed and the record
# before them half-zeroed (the one the write was filling). JSONL: cmd-1
# gains 300 zero bytes; evt-0's last line is cut short and zero-padded.
# The expected files are computed here, not by an implementation.
d="$V/repair/zerofill_fuzz_s11"
rm -rf "$d"; mkdir -p "$d"
for enc in jsonl binary; do
  flag=""; [ $enc = binary ] && flag=--binary
  src="$V/pipeline/fuzz_s11/P2/$enc"
  cp -R "$src" "$d/$enc.torn"; cp -R "$src" "$d/$enc.repaired"
  python3 - "$d/$enc.torn" "$d/$enc.repaired" $enc <<'PY'
import sys
torn, rep, enc = sys.argv[1:4]
def rd(p): return open(p, 'rb').read()
def wr(p, b): open(p, 'wb').write(b)
if enc == 'binary':
    c = rd(f'{torn}/cmd-0.bin'); wr(f'{torn}/cmd-0.bin', c + bytes(3 * 48 + 20))
    e = bytearray(rd(f'{torn}/evt-1.bin'))
    wr(f'{rep}/evt-1.bin', bytes(e[:-5 * 56]))
    e[-4 * 56:] = bytes(4 * 56)
    e[-5 * 56 + 28:-4 * 56] = bytes(28)
    wr(f'{torn}/evt-1.bin', bytes(e))
else:
    c = rd(f'{torn}/cmd-1.journal'); wr(f'{torn}/cmd-1.journal', c + bytes(300))
    e = rd(f'{torn}/evt-0.journal')
    last = e.rstrip(b'\n').rfind(b'\n') + 1
    wr(f'{rep}/evt-0.journal', e[:last])
    wr(f'{torn}/evt-0.journal', e[:last] + e[last:last + 15] + bytes(100))
PY
  "$BIN/orderrecover" --journal-dir "$d/$enc.repaired" $flag --partitions 2 > "$d/recov.$enc.evt"
done

# ---- compat: version-1 binary journals (read-only; committed as-is) ---------
[ -d "$V/compat/v1/fuzz_s11_P2/binary" ] || { echo "missing vectors/compat/v1"; exit 1; }

# ---- manifest ----------------------------------------------------------------
python3 - "$V" <<'EOF'
import json, os, sys
V = sys.argv[1]
def files(*paths):
    out = []
    for p in paths:
        full = os.path.join(V, p)
        if os.path.isdir(full):
            for d, _, fs in sorted(os.walk(full)):
                out += sorted(os.path.relpath(os.path.join(d, f), V) for f in fs if not f.startswith('.'))
        else:
            out.append(p)
    return out
vectors = [
    {"name": "routing/hash", "kind": "routing-hash",
     "desc": "ROUTING.md §2 reference values: symbols × partition counts",
     "files": files("routing/hash.jsonl")},
    {"name": "routing/table", "kind": "routing-table",
     "desc": "ROUTING.md §3 partition table overrides + hash fallback",
     "files": files("routing/table.map.jsonl", "routing/table.expect.jsonl")},
]
for f in sorted(os.listdir(os.path.join(V, "regress"))):
    if f.endswith(".cmd.jsonl"):
        n = f[:-len(".cmd.jsonl")]
        vectors.append({"name": "regress/" + n, "kind": "golden",
            "desc": "matcher-format golden vector (P=1 byte-exact, every index mode)",
            "files": files("regress/%s.cmd.jsonl" % n, "regress/%s.evt.jsonl" % n)})
for inp in ["multisymbol", "fuzz_s11"]:
    vectors.append({"name": "pipeline/" + inp, "kind": "pipeline",
        "desc": "orderrun listing + per-partition JSONL and binary journals at P=1,2,4",
        "input": "pipeline/%s.cmd.jsonl" % inp, "partitions": [1, 2, 4],
        "files": files("pipeline/%s.cmd.jsonl" % inp, "pipeline/" + inp)})
for inp in ["multisymbol", "fuzz_s11"]:
    vectors.append({"name": "checkpoint/" + inp, "kind": "checkpoint",
        "desc": "JOURNAL.md 1.2 §6: orderrun --checkpoint-every K at P=2 (listing = pipeline/<input>/P2); journal dirs hold the last checkpoint + its segments; recov.evt = orderrecover from the checkpoint",
        "input": "pipeline/%s.cmd.jsonl" % inp, "partitions": 2,
        "files": files("checkpoint/" + inp)})
vectors.append({"name": "repair/fuzz_s11", "kind": "repair",
    "desc": "JOURNAL.md 1.2 §5.1: <enc>.torn = P=2 journals with torn tails; orderrecover --repair --partitions 2 on a copy leaves <enc>.repaired and prints recov.<enc>.evt; strict recovery of .torn exits 2",
    "partitions": 2, "files": files("repair/fuzz_s11")})
vectors.append({"name": "repair/rotation_fuzz_s11", "kind": "repair",
    "desc": "JOURNAL.md 1.3 §5.1: <enc>.torn = checkpoint/fuzz_s11 with partition 0's segments torn behind header-only next segments; orderrecover --repair --partitions 2 repairs the torn ones and keeps the header-only ones, leaving <enc>.repaired (computed independently), and prints recov.<enc>.evt; strict recovery of .torn exits 2",
    "partitions": 2, "files": files("repair/rotation_fuzz_s11")})
vectors.append({"name": "repair/zerofill_fuzz_s11", "kind": "repair",
    "desc": "JOURNAL.md 1.3 §5.1: <enc>.torn = fuzz_s11 P=2 journals extended by zeros an interrupted write left (zero records, a half-filled record; JSONL zero bytes); orderrecover --repair --partitions 2 leaves <enc>.repaired (computed independently) and prints recov.<enc>.evt; strict recovery of .torn exits 2",
    "partitions": 2, "files": files("repair/zerofill_fuzz_s11")})
vectors.append({"name": "repair/checkpoint_fuzz_s11", "kind": "repair",
    "desc": "JOURNAL.md 1.3 §5.1: <enc>.torn = checkpoint/fuzz_s11 plus next-checkpoint segments without a usable header (partial, empty, zero-filled); orderrecover --repair --partitions 2 deletes them, leaving <enc>.repaired, and prints recov.<enc>.evt; strict recovery of .torn exits 2",
    "partitions": 2, "files": files("repair/checkpoint_fuzz_s11")})
vectors.append({"name": "compat/v1/fuzz_s11_P2", "kind": "compat",
    "desc": "version-1 binary journals (orderer-spec/1.1 writers); 1.2 readers recover them: orderrecover --binary --partitions 2 matches listing.evt per symbol",
    "partitions": 2, "files": files("compat/v1/fuzz_s11_P2")})
vectors.append({"name": "recovery/fuzz_s11", "kind": "recovery",
    "desc": "orderrun prefix --snap at P=3, then orderrecover snap+tail at P=1 and P=3",
    "snapshot_partitions": 3, "partitions": [1, 3],
    "files": files("recovery/fuzz_s11")})
m = {"format": "orderer-vectors-manifest/1", "includes": ["matcher/manifest.json"], "vectors": vectors}
with open(os.path.join(V, "manifest.json"), "w") as f:
    json.dump(m, f, indent=2)
    f.write("\n")
print("manifest: %d vectors, %d files" % (len(vectors), sum(len(v["files"]) for v in vectors)))
EOF
scripts/manifest.sh
