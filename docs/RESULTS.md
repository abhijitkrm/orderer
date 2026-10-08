# RESULTS — orderer benchmark matrix

Protocol and row format: `spec/BENCH.md`. Latencies are in nanoseconds.
Core rows report per-op latency; pipeline rows report end-to-end latency
(publish → first event at egress). `eff` = pipeline ops/s ÷ (P × core ops/s)
on the same workload.

Pipeline latencies below come from **open-loop saturation runs**: one
producer publishes the whole corpus as fast as the ingress accepts it. They
measure queueing delay at full load (milliseconds), not service time.

## Phase 2.5 spike — orderer-rust @ 2026-10-08 dc69938

env: Apple M1 (4 performance + 4 efficiency cores, 128 B lines) / macOS
13.0.1 / rustc 1.98.1 (lto=fat, cgu=1) / W6 64 symbols, 10M run commands
(`ordergen --workload w6 --symbols 64 --n 10000000`), waits=low (router +
engines busy-spin), journal and egress stages on 1 thread each.

| workload | mode | P | prod | ops | ops/s | eff | config |
|---|---|---|---|---|---|---|---|
| w6 | core | - | - | 10M | 9,734,297 | | single `Engine` |
| w6 | pipe | 1 | 1 | 10M | 14,311,920 | 1.47 | journal off |
| w6 | pipe | 2 | 1 | 10M | 26,912,337 | 1.38 | journal off |
| w6 | pipe | 3 | 1 | 10M | 27,575,829 | 0.94 | journal off |
| w6 | pipe | 4 | 1 | 10M | 29,553,706 | 0.76 | journal off |
| w6 | pipe | 1 | 1 | 10M | 10,238,842 | 1.05 | binary cmd journal, F_FULLFSYNC group commit |
| w6 | pipe | 2 | 1 | 10M | 15,727,469 | 0.81 | binary cmd journal, F_FULLFSYNC group commit |
| w6 | pipe | 3 | 1 | 10M | 19,886,613 | 0.68 | binary cmd journal, F_FULLFSYNC group commit |
| w6 | pipe | 4 | 1 | 10M | 22,084,704 | 0.57 | binary cmd journal, F_FULLFSYNC group commit |

`NoopCore` (no matching, so the pipeline alone; 2M commands): 63–67M cmds/s
at P=2, which passes the ≥ 60M go/no-go. `FifoCore` with journals off
scales at ≥ 0.9 efficiency at P=2. **Verdict: go.** The topology stands.

`eff > 1` at low P is real but partly flattering. The core baseline times
every op individually (two clock reads per command, matcher protocol). A
pipeline engine also works on fewer symbols, so its books stay hotter in
cache.

### Findings that shape phase 6

1. **Performance cores run out at P ≥ 3.** The router plus P busy-spinning
   engines want P+1 performance cores, and this M1 has 4. Journal-off
   scaling flattens at P=3–4 (28–30M) even though the pipeline alone does
   60M+.
2. **Durable journaling is disk-bound.** macOS's real durability primitive
   is `F_FULLFSYNC`, which flushes the whole drive cache. Measured raw:
   about 0.9 GB/s for one file with 16 MB group commits, but only about
   0.4 GB/s with 2–4 files fsyncing in parallel. At 40 B per command
   record, that caps durable journaling at roughly 10–22M commands/s on
   this machine. `NoopCore` with durable journals tops out at about 23M
   regardless of P, which confirms the bottleneck is I/O, not the pipeline.
3. **Syscalls must stay off the pipeline threads.** A single `write()`
   stalled up to 25 ms under page-cache pressure or a concurrent
   `F_FULLFSYNC`. orderer-rust therefore encodes journal records into
   recycled 256 KB chunks and writes and fsyncs them on dedicated
   blocking I/O threads, with group commit: write everything queued, then
   one fsync. Before that change, durable throughput was 2–5M/s.
4. **Event journals cost about 2.5× the command journal's bytes.** That
   motivated the `spec/BENCH.md` gated configuration (command journals
   only; event journals are re-derivable).
