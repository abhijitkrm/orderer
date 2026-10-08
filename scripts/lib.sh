# lib.sh — shared plumbing for the cross-implementation scripts. Source it.
#
# orderer implementations follow the spec/HARNESS.md §6 discovery contract:
# each repo provides scripts/build-harness.sh (tools → harness/bin/) and
# scripts/test.sh. Locations default to siblings of this repo and can be
# overridden with ORDERER_<LANG>_DIR. Absent implementations are skipped
# with a notice — only orderer-rust exists at first.
#
# matcher implementations (the down-axis references) are driven the way
# matcher's own scripts drive them; MATCHER_<LANG>_DIR overrides, default
# ~/Documents/matcher-<lang> or ../matcher-<lang>.

ORDERER_LANGS="rust cpp java go ts"
MATCHER_LANGS="rust go cpp ts java"

upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

orderer_dir() {
  local v="ORDERER_$(upper "$1")_DIR"
  echo "${!v:-$ROOT/../orderer-$1}"
}

matcher_dir() {
  local v="MATCHER_$(upper "$1")_DIR"
  if [ -n "${!v:-}" ]; then echo "${!v}"; return; fi
  if [ -d "$ROOT/../matcher-$1" ]; then echo "$ROOT/../matcher-$1"; else echo "$HOME/Documents/matcher-$1"; fi
}

# Present orderer impls, reference (rust) first.
orderer_present() {
  local out=""
  for l in $ORDERER_LANGS; do
    if [ -x "$(orderer_dir "$l")/scripts/build-harness.sh" ]; then out="$out $l"
    else echo "   (orderer-$l not found at $(orderer_dir "$l") — skipped)" >&2; fi
  done
  echo $out
}

matcher_present() {
  local out=""
  for l in $MATCHER_LANGS; do
    if [ -d "$(matcher_dir "$l")" ]; then out="$out $l"
    else echo "   (matcher-$l not found — skipped)" >&2; fi
  done
  echo $out
}

build_orderer() { (cd "$(orderer_dir "$1")" && CHECKED="${CHECKED:-0}" scripts/build-harness.sh); }

# ot <lang> <tool> [args…] — run an orderer harness tool.
ot() { local l=$1 t=$2; shift 2; "$(orderer_dir "$l")/harness/bin/$t" "$@"; }

# Build matcher-<lang>'s harnesses (matcherfuzz/run/recover/snap) into $MWORK.
build_matcher() {
  local l=$1 d; d=$(matcher_dir "$l")
  mkdir -p "$MWORK"
  case $l in
    rust) (cd "$d" && cargo build --quiet --release --bins 2>/dev/null) ;;
    go)   for t in matcherfuzz matcherrun matcherrecover matchersnap matcherbench; do
            (cd "$d" && go build -o "$MWORK/go-$t" "./cmd/$t"); done ;;
    cpp)  (cd "$d" && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null \
            && cmake --build build --target matcherfuzz matcherrun matcherrecover matchersnap matcherbench -j >/dev/null) ;;
    ts)   (cd "$d" && npm run build >/dev/null 2>&1) ;;
    java) (cd "$d" && mkdir -p out && javac -d out --release 17 \
            src/main/java/io/github/abhijitkrm/matcher/*.java \
            tests/MatcherFuzz.java tests/MatcherRun.java tests/MatcherRecover.java tests/MatcherSnap.java \
            bench/MatcherBench.java) ;;
  esac
}

# mt <lang> <tool> [args…] — run a matcher harness (tool ∈ matcherfuzz,
# matcherrun, matcherrecover, matchersnap).
mt() {
  local l=$1 t=$2 d; shift 2; d=$(matcher_dir "$l")
  case $l in
    rust) "$d/target/release/$t" "$@" ;;
    go)   "$MWORK/go-$t" "$@" ;;
    cpp)  "$d/build/$t" "$@" ;;
    ts)   node "$d/dist/bench/$t.js" "$@" ;;
    java) local c; case $t in matcherfuzz) c=MatcherFuzz;; matcherrun) c=MatcherRun;;
            matcherrecover) c=MatcherRecover;; matchersnap) c=MatcherSnap;; esac
          java -cp "$d/out" "$c" "$@" ;;
  esac
}

# mbench <lang> <prefix> — matcher-<lang>'s own matcherbench (spec/BENCH.md of
# matcher): the matching core alone, single book. Prints its RESULTS row.
mbench() {
  local l=$1 d; shift; d=$(matcher_dir "$l")
  case $l in
    rust) "$d/target/release/matcher_bench" "$@" ;;
    go)   "$MWORK/go-matcherbench" "$@" ;;
    cpp)  "$d/build/matcherbench" "$@" ;;
    ts)   node "$d/dist/bench/matcherbench.js" "$@" ;;
    java) java -cp "$d/out" MatcherBench "$@" ;;
  esac
}

# Per-symbol view of a symbol-tagged listing: stable sort by symbol.
bysym() {
  awk 'match($0, /"symbol":[0-9]+/) { print substr($0, RSTART+9, RLENGTH-9) "\t" $0 }' "$1" \
    | sort -s -n -k1,1 | cut -f2-
}

# Per-symbol seq must be dense from 1.
seqcheck() {
  awk '
    match($0, /"seq":[0-9]+/) { seq = substr($0, RSTART+6, RLENGTH-6) }
    match($0, /"symbol":[0-9]+/) { sym = substr($0, RSTART+9, RLENGTH-9); nextseq[sym]++ ;
      if (seq != nextseq[sym]) { printf "seq gap: sym %s expected %d got %d\n", sym, nextseq[sym], seq; bad=1 } }
    END { exit bad }
  ' "$1"
}

ordergen() {
  [ -x "$ROOT/tools/ordergen/target/release/ordergen" ] \
    || cargo build --quiet --release --manifest-path "$ROOT/tools/ordergen/Cargo.toml"
  "$ROOT/tools/ordergen/target/release/ordergen" "$@"
}
