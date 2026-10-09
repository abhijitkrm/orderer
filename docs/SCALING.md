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

## Running the matrix on a Linux server

Every number in `docs/RESULTS.md` so far comes from one Apple M1 laptop:
4 performance cores, and an SSD on which `F_FULLFSYNC` averages about
12 ms (`orderbench --stats` reports it). Both limit the durable rows, so
the scaling gate there says more about the laptop than about orderer.
Representative numbers need a server. The scripts run unchanged on Linux
(CI already builds and tests every port on Ubuntu).

What to use:

- At least 2P + 3 physical cores free for the run (producer, router, P
  engines, egress, journal I/O), on one NUMA node.
- An NVMe drive with power-loss protection. Journals sync with
  `fdatasync` on Linux; on such drives a flush takes tens of microseconds,
  not milliseconds.
- The performance governor, turbo off for stable results, and nothing else
  running.

How to run it:

```bash
# siblings: orderer, orderer-{rust,cpp,java,go,ts}, matcher-{rust,go,cpp,ts,java}
sudo cpupower frequency-set -g performance
cd orderer
scripts/bench.sh --n 10000000                 # all present ports, isolated + integrated
# one port, confined to chosen cores, with fsync timing:
taskset -c 2-9 ../orderer-rust/harness/bin/orderbench bench/w6-10000000 --mode pipe --partitions 4 --stats
```

orderer does not pin threads itself on Linux (orderer-rust's `affinity`
feature only sets macOS QoS hints), so confine the process with `taskset`
or cgroups. Record the CPU model, core count, kernel, drive model and filesystem with
the rows (CONTRIBUTING.md). To isolate the drive's effect, compare
`--journal off` with the durable rows, and read fsync timing from `--stats`.
