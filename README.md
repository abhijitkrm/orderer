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

- **orderer-spec/1.2** is tagged. All five implementations (Rust, C++,
  Java, Go, TypeScript) implement it and are byte-identical to each other
  and to all five matcher ports: differential fuzzing (per-partition
  journals included), bounded exhaustive checking, snapshot diffs, a
  150-way cross-restore matrix, and the shared `spec/conformance.sh`.
- **1.2 adds durability features**: CRC-32C on every binary journal record,
  crash repair for torn tails, and checkpoints that rotate journals onto
  segments and delete what a durable snapshot covers (manual or
  automatic). `scripts/crash.sh` SIGKILLs durable runs of every port and
  checks that every acknowledged command survives.
- **Every port exposes `stats()`**: ring depths, counters, durability
  watermarks and fsync timings, with Prometheus text output.
- **Performance** (Apple M1, W6, one producer; [`docs/RESULTS.md`](docs/RESULTS.md)):
  Rust and C++ reach about 32M commands/s with journals off and 18–21M
  durable; Java 20M / 15M; Go 13M / 14M; TypeScript 8M / 6M. The durable
  scaling gate is **not met** on that machine: an `F_FULLFSYNC` there
  averages ~12 ms.
- **Found and fixed upstream** ([`docs/UPSTREAM.md`](docs/UPSTREAM.md)):
  bugs and performance problems in matcher-rust, matcher-cpp and matcher-go,
  each with a regression test or vector.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
