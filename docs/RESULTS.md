# RESULTS — orderer benchmark matrix

Protocol and row format: `spec/BENCH.md`. Latencies are in nanoseconds.
Core rows report per-op latency; pipeline rows report end-to-end latency
(publish → first event at egress). `eff` = pipeline ops/s ÷ (P × core ops/s)
on the same workload.

Pipeline latencies below come from **open-loop saturation runs**: one
producer publishes the whole corpus as fast as the ingress accepts it. They
measure queueing delay at full load (milliseconds), not service time.

## orderer-rust + orderer-cpp — 2026-10-08 (gated configuration, late session)

Same machine, `COOLDOWN=30 scripts/bench.sh --n 10000000`, both
implementations back to back. The SSD had absorbed tens of GB of durable
writes by this point (disk 85% full). Durable rows are lower than the
phase-6 runs below and show 15–58 ms p99 stalls. Read them as
disk-limited, not as a regression.

| impl | workload | mode | P | ops/s | eff | p50 / p99 e2e | config |
|---|---|---|---|---|---|---|---|
| orderer-rust 2eae420 | w4 | core | - | 11,124,765 | | 42 / 416 ns | untimed=23,951,044 |
| orderer-rust | w6 | core | - | 6,676,852 | | 83 / 542 ns | untimed=13,107,299 |
| orderer-rust | w6 | pipe | 1 | 7,559,909 | 0.58 | 1.7 / 25 ms | binary, fsync 1024 |
| orderer-rust | w6 | pipe | 2 | 17,680,590 | 0.67 | 1.0 / 5.0 ms | binary, fsync 1024 |
| orderer-rust | w6 | pipe | 3 | 13,681,261 | 0.35 | 1.1 / 22 ms | binary, fsync 1024 |
| orderer-rust | w6 | pipe | 4 | 15,736,269 | 0.30 | 1.3 / 14 ms | binary, fsync 1024 |
| orderer-cpp dbda998 | w4 | core | - | 10,467,167 | | 42 / 459 ns | untimed=16,070,237 |
| orderer-cpp | w6 | core | - | 11,854,229 | | 42 / 459 ns | untimed=23,112,485 |
| orderer-cpp | w6 | pipe | 1 | 10,052,976 | 0.43 | 1.9 / 4.1 ms | binary, fsync 1024 |
| orderer-cpp | w6 | pipe | 2 | 14,871,522 | 0.32 | 1.1 / 11 ms | binary, fsync 1024 |
| orderer-cpp | w6 | pipe | 3 | 14,880,637 | 0.21 | 1.0 / 23 ms | binary, fsync 1024 |
| orderer-cpp | w6 | pipe | 4 | 13,686,063 | 0.15 | 1.2 / 16 ms | binary, fsync 1024 |

Reading it:

- **Cores differ; pipelines converge.** The matcher-cpp core is about 1.8×
  matcher-rust's on multi-symbol W6, untimed: 23.1M vs 13.1M. Rust's
  default `HashMap` (SipHash) on every symbol lookup is the likely cause,
  a candidate matcher-rust optimisation. On single-book W4, Rust leads (24M
  vs 16M). With durable journals, both pipelines land at 10–18M, because
  both are bound by the same disk. A faster core therefore shows a *lower*
  `eff`. The gate is relative to each language's own core, by design.
- **A4 is not met by either implementation on this machine.** The limits
  are the same as in the phase-6 analysis below: `F_FULLFSYNC` flush
  bandwidth, which degrades as the SSD fills over a session, and 4
  performance cores.

## Phase 6 — orderer-rust @ 2026-10-08 cd5cd39 (gated configuration)

env: Apple M1 (4 performance + 4 efficiency cores) / macOS 13.0.1 / rustc
1.98.1 (lto=fat, cgu=1, panic=abort) / W6 64 symbols, 10M run commands /
binary command journals, `F_FULLFSYNC` group commit at ≥ 1024 records /
inline journaling, rings 16K/4K/8K, waits=low (router + engines
busy-spin). Two back-to-back sessions of `COOLDOWN=45 scripts/bench.sh`.
`eff` uses the **untimed** core baseline (spec/BENCH.md 1.1).

| workload | mode | P | prod | ops | ops/s (run 1) | eff | ops/s (run 2) | eff | p50 / p99 e2e (run 2) |
|---|---|---|---|---|---|---|---|---|---|
| w4 | core | - | - | 1M | 12,016,884 (untimed 25,538,055) | | 12,117,430 (untimed 25,379,261) | | 42 ns / 334 ns per op |
| w6 | core | - | - | 10M | 6,688,597 (untimed 13,125,273) | | 5,574,998 (untimed 14,084,829) | | 125 ns / 667 ns per op |
| w6 | pipe | 1 | 1 | 10M | 10,771,823 | 0.82 | 12,136,508 | 0.86 | 1.5 ms / 3.4 ms |
| w6 | pipe | 2 | 1 | 10M | 17,520,779 | 0.67 | 18,546,930 | 0.66 | 0.95 ms / 3.9 ms |
| w6 | pipe | 3 | 1 | 10M | 10,175,215 | 0.26 | 16,786,608 | 0.40 | 1.1 ms / 17 ms |
| w6 | pipe | 4 | 1 | 10M | 16,677,038 | 0.32 | 15,256,048 | 0.27 | 1.3 ms / 19 ms |

Best single runs seen earlier the same day, with a cooler machine and SSD,
same code and configuration: P=2 18.8M (0.97 against that run's timed
baseline, about 0.65 untimed), P=3 23.6M, P=4 22.8M.

Core parity with matcher-rust's `matcher_bench` (same machine, interleaved,
best of 2): W2 14.36M vs 13.95M, W4 12.06M vs 12.24M, W5 12.04M vs 12.07M.
**Within ±10%.**

### A4 verdict: **not met on this machine**

The hard gate is `eff ≥ 0.9` at P ∈ {1, 2, 4} with durable journals.
Measured: P=1 0.82–0.86, P=2 0.66–0.67, P=4 0.27–0.32. The 40M stretch
was not reached either. The best aggregate seen was 31.3M with journals
off (P=3) and 23.6M durable (P=3). Per the plan, A4 is reported as missed,
not lowered. The gap, quantified:

1. **Durable bandwidth is the binding limit at P ≥ 2.** Each command
   journals 40 bytes. `F_FULLFSYNC`, macOS's only true durability
   primitive, flushes the whole drive cache. Measured raw: about 0.9 GB/s
   for one file with 16 MB group commits, and about 0.4 GB/s with several
   files syncing. Sustained throughput also *degrades over a session*: each
   10M run writes about 400 MB, and later sessions show 13–33 ms p99 write
   stalls. That is consistent with the SSD's fast write cache being
   exhausted, on a disk 83% full. At P=3, journals off gives eff 1.07 (31.3M
   against the 9.7M timed baseline of that session). The same code with
   durable journals gives 0.81 on a cool machine and 0.26–0.40 on a
   saturated one.
2. **Performance cores run out at P ≥ 3.** The router, the producer and P
   engines all busy-spin, so P=4 needs 6 hot threads on 4 performance
   cores. With journals off, P=4 still reaches only eff 0.75. QoS hints
   (feature `affinity`) didn't help: hot-only hints were within noise, and
   demoting the I/O threads cost 20–30%.
3. **P=1 at 0.82–0.86 is the pipeline's fixed cost.** One engine pays for
   ring handoffs plus in-thread journal encoding. With journals off, P=1 is
   0.99 against the untimed baseline (14.3M vs 14.5M).
4. **Machine noise.** This is likely a fanless M1. The same core benchmark
   ranged 5.5–9.7M (timed) across the day. `COOLDOWN` reduces the
   variance but doesn't remove it.

### What it would take

- **Hardware matching the shape.** At least P+2 performance cores, and NVMe
  with power-loss protection, where fsync completes without flushing a
  volatile cache, so group commit costs microseconds rather than
  milliseconds. The pipeline itself (`NoopCore`) sustains 63–67M.
- **Fewer bytes per command.** A varint or delta binary encoding (about 12
  B instead of 40) would triple the durable ceiling. That is a candidate for
  orderer-spec/2: it is a wire-format change for every port.
- **Producer-side routing.** It would remove the router hop and its
  performance core (plan §7.5's documented fallback), if a deployment's
  producers can stamp a global sequence.

### Tuning applied in phase 6

| Lever | Effect (W6, P=2 unless noted) | Kept? |
|---|---|---|
| Journal I/O off the pipeline threads (chunked writer, per-file I/O threads, group commit) | durable throughput from 2–5M to 15–19M | yes |
| Inline journaling (engine encodes, no journal stage) | eff 0.86 → 0.97 (timed baseline) at P=2; 0.63 → 0.81 at P=3 | yes, default |
| Journal/egress stages grouped onto 1 thread each | fewer threads competing for 4 P-cores | yes |
| Rings 64K/16K/32K → 16K/4K/8K | +5% throughput, about 4× lower p50 queueing | yes, default |
| Producer claim batch 64 → 256 | within noise | no |
| QoS hints (feature `affinity`) | hot-only: noise; demoting I/O: −20–30% | feature-gated, hot-only |
| Journal-stage wait strategies (yield/spin) | stage placement only; superseded by inline | n/a |

## Phase 2.5 spike — orderer-rust @ 2026-10-08 dc69938

(`eff` here uses the per-op-timed core baseline of orderer-spec/1, which
overstates efficiency by about 1.5× — see the phase 6 section.)

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
