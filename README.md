# orderer

[![license](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](LICENSE-MIT)

**The specification repo for the orderer project**: a multi-core,
LMAX-Disruptor-style order-matching engine built around the
[matcher](https://github.com/abhijitkrm/matcher) order book, with one
idiomatic implementation per language.

matcher is a *library*: a single-writer order book per symbol that
deliberately ships no threads, queues or journals ("the caller supplies
sequencing"). orderer is that caller. It provides the runnable engine:
sequenced ingress, journal-before-apply, symbol partitioning across cores,
and multicast egress. It keeps matcher's guarantee that the same input
produces a byte-identical output in every language.

This repo holds the shared contract: the pipeline spec, golden vectors,
generators and cross-implementation scripts. The engines live in their own
repos and prove byte-identical behavior against `vectors/`.

## Implementations

| Repo | Language | Status |
|---|---|---|
| [orderer-rust](https://github.com/abhijitkrm/orderer-rust) | Rust | reference implementation, `orderer-spec/1.1` |
| [orderer-cpp](https://github.com/abhijitkrm/orderer-cpp) | C++20 | header-only, `orderer-spec/1.1`, byte-identical to orderer-rust |
| [orderer-java](https://github.com/abhijitkrm/orderer-java) | Java 17+ | `orderer-spec/1.1`, byte-identical to orderer-rust |
| [orderer-go](https://github.com/abhijitkrm/orderer-go) | Go 1.21+ | `orderer-spec/1.1`, byte-identical to orderer-rust |
| [orderer-ts](https://github.com/abhijitkrm/orderer-ts) | TypeScript (Node 18+) | `worker_threads` + SharedArrayBuffer, `orderer-spec/1.1`, byte-identical to orderer-rust |

Each `orderer-<lang>` embeds a vendored port of the matching `matcher-<lang>`
core.

## The design

```
producers ─▶ INGRESS RING ─▶ ROUTER ─▶ inbox[p] ─▶ journal[p] ─▶ engine[p] ─▶ outbox[p] ─▶ egress[p]
 (any thread)  global seq     symbol→p    SPSC      cmd journal    matcher      SPSC        journal, acks,
                                                    (before apply)  Engine                  metrics, callbacks
```

- **One global sequenced ingress ring.** Every command gets a total-order
  `iseq`.
- **Static symbol → partition routing.** The routing function is pinned
  exactly in the spec, so every language routes identically
  (`spec/ROUTING.md`).
- **Journal-before-apply per partition.** It is a structural dependency (the
  LMAX diamond), not a synchronous call, so journal I/O scales with cores.
  Acks wait for fsync (`spec/PIPELINE.md`).
- **Per-partition egress fan-out.** Pluggable consumers each see every event
  in partition order.
- **Matcher semantics, unchanged.** At one partition, orderer's output is
  byte-identical to matcher's.

## Layout

```
spec/        PIPELINE.md (ordering, durability, control) · ROUTING.md (partition map) ·
             JOURNAL.md (per-partition journals, binary format, snapshots) ·
             HARNESS.md (CLI contract) · BENCH.md (pipeline benchmark protocol)
spec/matcher/     vendored matcher spec (semantics, vector schema, journal, bench)
vectors/routing/  partition-hash reference table, partition-table case
vectors/pipeline/ per-partition listings + JSONL and binary journals at P=1,2,4
vectors/recovery/ snapshot + tail → continuation, restored at a different P
vectors/regress/  matcher-format golden vectors orderer adds (e.g. dense_map_churn)
vectors/matcher/  vendored matcher golden corpus
tools/       ordergen: matcher-compatible workloads + multi-symbol corpora + fuzz
scripts/     verify · diffuzz · exhaustive · e2e · snapdiff · bench · vendored · manifest ·
             gen-vectors (regenerate vectors from the reference implementation)
docs/        RESULTS.md (cross-language matrix) · SCALING.md · VENDORED.md · UPSTREAM.md
```

## How parity works

Parity is checked in two directions:

- **Down: orderer-X vs matcher-X.** At one partition, a pipeline run emits
  exactly matcher's event stream. The pipeline adds no semantics.
- **Across: orderer-X vs orderer-Y.** Golden, fuzz and exhaustive streams,
  per-partition journals at P ∈ {1, 2, 4}, and snapshots are all
  byte-identical across languages. Routing and journal formats are
  specified to the byte, so even partition-level files are comparable.

Implementations are checked out as siblings (`../orderer-rust`, …). The
scripts skip any that are absent.

## Status

- **orderer-spec/1.1** is tagged. All five implementations (Rust, C++,
  Java, Go, TypeScript) implement it and are byte-identical to each other
  and to all five matcher ports: differential fuzzing (8 seeds,
  per-partition journals included), bounded exhaustive checking (512
  sequences, depth 3), snapshot diffs, and a 150-way cross-restore matrix.
- **Performance** (Apple M1, W6, one producer; [`docs/RESULTS.md`](docs/RESULTS.md)
  has every row): Rust and C++ reach 28–30M cmds/s with journals off and
  about 22M durable; Java 15M / 9M; Go 10M / 7M; TypeScript 7M / 7M. The
  durable scaling gate is **not met** on that machine, because of the
  drive's flush bandwidth and its 4 performance cores.
- **Found and fixed upstream** ([`docs/UPSTREAM.md`](docs/UPSTREAM.md)): an
  order-map deletion bug in matcher-rust and matcher-cpp (with a
  regression vector in `vectors/regress/`), a per-command book
  construction in matcher-cpp's `Engine`, and a 16 GiB-per-snapshot
  allocation in matcher-go.
- **Next:** the Go pipeline's GC behaviour (see RESULTS.md), and multiple
  publishing threads for orderer-ts.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
