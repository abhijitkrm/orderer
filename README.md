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
| orderer-cpp | C++20 | planned |
| orderer-java | Java 17+ | planned |
| orderer-go | Go | planned |
| orderer-ts | TypeScript | planned |

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

- **orderer-spec/1.1** is tagged. orderer-rust implements it. It is
  byte-identical to all five matcher ports under differential fuzzing (8
  seeds) and bounded exhaustive checking (depth 3), and passes the 42-way
  cross-restore matrix.
- **Performance** (Apple M1): the pipeline alone runs at 63–67M cmds/s;
  durable, it reaches up to about 24M. The scaling gate is **not met** on
  that machine, because of the drive's flush bandwidth and its 4
  performance cores. [`docs/RESULTS.md`](docs/RESULTS.md) has the matrix and
  the gap analysis.
- **Found upstream:** an order-map deletion bug in matcher-rust and
  matcher-cpp ([`docs/UPSTREAM.md`](docs/UPSTREAM.md)), with a regression
  vector in `vectors/regress/`.
- **Next:** the orderer-cpp, -java, -go and -ts ports, each against
  `orderer-spec/1.1` (porting checklist: orderer-rust `docs/DESIGN.md` §8).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
