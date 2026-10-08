# SCALING — how orderer uses cores

matcher's `docs/SCALING.md` sets the rules: one writer per book,
partitioning by symbol, and per-engine journals. orderer is that model made
runnable. This note explains the mapping. The contract is in
`spec/PIPELINE.md`.

## The shape

```
producers ──▶ ingress ring ──▶ router ──┬─▶ partition 0: journal → engine → egress
  (any)        (total order)    (1 thr) ├─▶ partition 1: journal → engine → egress
                                        └─▶ …
```

- **Partition = the matcher engine thread** from matcher's SCALING.md. Its
  `Engine` owns a static set of symbols (`spec/ROUTING.md`) and is its only
  writer. Partitions share no state, so throughput scales with partitions
  until something shared saturates.
- **The shared things** are the ingress ring (one atomic claim per
  producer batch) and the router (one thread touching every command). These
  are the bottlenecks to watch. The scaling gate (`spec/BENCH.md` §5)
  exists to measure them.
- **Per-partition journals** follow "one input queue + one output journal per
  engine". A single global journal writer would cap the whole pipeline at
  one core's I/O throughput.

## Ordering

- Per symbol: total, identical to matcher.
- Per partition: total.
- Across partitions: none. Consumers merge by per-book `seq` or by `iseq`.
  This is the per-channel sequencing model of ITCH and iLink. A global
  ordered event stream would make every partition wait on the slowest.

## Rebalancing

Snapshots are partition-independent (`spec/JOURNAL.md` §4). To move symbols:

1. Snapshot.
2. Restart with a new `P` or partition table.
3. Restore.

Live migration stays out of scope, as in matcher.

## Choosing P

Each partition needs a core for its engine thread, which busy-spins in
low-latency configurations. The router needs one too. Journal and egress
threads can share the remaining cores, because they batch and back off.
On a machine with `C` performance cores, start at `P = C − 1` and measure.
The implementation's `docs/DESIGN.md` records its thread budget and the
measured best P.

## Measured (orderer-rust, Apple M1 4P+4E)

- The pipeline alone (no matching) sustains 63–67M commands/s at P=2. The
  ring, router and egress machinery is not the limit.
- With matching and journals off, P=1 runs at about the core's own speed,
  and P=2 nearly doubles it. P=3–4 flatten: the router, the producer and P
  busy-spinning engines want P+2 performance cores.
- With durable journals, the drive's flush bandwidth is the ceiling. Inline
  journaling (each engine encodes its own records) beats a separate
  journal stage when cores are scarce.

Numbers and analysis: `docs/RESULTS.md`.
