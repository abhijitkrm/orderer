# Changelog

## orderer-spec/1.3

- JOURNAL.md §5.1: repair deletes a segment that cannot hold a record and
  whose start is above 0 (JSONL with no newline; binary no longer than the
  header with an invalid header). A crash between creating segment `N` at
  a checkpoint and writing its header left one, and every implementation's
  `--repair` refused the directory. Found by `scripts/crash.sh`, whose
  checkpoint rounds now rotate every N/30 commands to exercise it.
- JOURNAL.md §5.1: binary repair cuts every final record that is entirely
  zero bytes before the one-record checksum rule. On macOS, SIGKILL during
  a large write can leave a file extended by zeros where the data never
  landed (crash.sh found whole 256 KB chunks of them).
- Vectors `repair/checkpoint_fuzz_s11` (partial, empty and zero-filled
  headers) and `repair/zerofill_fuzz_s11` (zero records, a half-filled
  record, JSONL zero bytes); `spec/conformance.sh` runs every repair vector.
- Vendored matcher `06b5403` (BENCH.md W3-drain row).

## orderer-spec/1.2

- JOURNAL.md: binary journal version 2 (CRC-32C per record), repair mode
  for torn tails (§5.1), segments and checkpoints (§6).
- HARNESS.md: `orderrun --checkpoint-every K` and `--durable`,
  `orderrecover --repair`.
- `spec/conformance.sh`, the shared harness test every implementation
  runs; `scripts/crash.sh`, SIGKILL durability test.
- Vectors: `checkpoint/`, `repair/fuzz_s11`, `compat/v1`.

## orderer-spec/1.1

- BENCH.md: the scaling gate's denominator is now the core's **untimed**
  throughput (stricter; the per-op-timed figure overstated `eff` by about
  1.5×). Core rows report `untimed=`.
- docs/RESULTS.md: phase 6 matrix and A4 gap analysis. docs/UPSTREAM.md:
  matcher order-map bug report.

## orderer-spec/1

- HARNESS.md §6: discovery contract (`scripts/build-harness.sh`,
  `scripts/test.sh`). Cross-implementation scripts: verify, diffuzz,
  exhaustive, e2e, snapdiff, bench (`scripts/lib.sh`).

- Vectors: routing hash table + partition-table case, per-partition
  pipeline listings and journals (JSONL + binary) at P=1,2,4, a recovery case
  restored at a different P, and `regress/001_dense_map_churn` — a golden
  vector exposing an order-map deletion bug in matcher-rust and matcher-cpp
  (matcher-java/-ts agree with the expected stream). `scripts/gen-vectors.sh`.
- JOURNAL.md: journal headers carry the book config (JSONL keys; binary
  header is 64 bytes), so journal-only recovery is self-describing.
- `tools/ordergen`: matcher vectorgen + fuzzgen superset, plus W6.
- Spec drafts: PIPELINE, ROUTING, JOURNAL, HARNESS, BENCH.
- Spec repo scaffold. Vendored matcher spec + golden corpus at
  `79d1964` (`docs/VENDORED.md`), with checksum verification
  (`scripts/vendored.sh`) and a manifest completeness check
  (`scripts/manifest.sh`).
