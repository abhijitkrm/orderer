# Changelog

## Unreleased

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
