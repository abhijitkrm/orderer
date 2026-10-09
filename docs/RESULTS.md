# RESULTS — orderer benchmark matrix

Protocol and row format: `spec/BENCH.md`. Latencies are in nanoseconds.
Core rows report per-op latency; pipeline rows report end-to-end latency
(publish → first event at egress). `eff` = pipeline ops/s ÷ (P × core ops/s)
on the same workload.

Pipeline latencies below come from **open-loop saturation runs**: one
producer publishes the whole corpus as fast as the ingress accepts it. They
measure queueing delay at full load (milliseconds), not service time.

## 0.2.0 / orderer-spec 1.2: all five ports after the improvement round (2026-10-09)

`COOLDOWN=5 scripts/bench.sh --n 10000000`, same Apple M1, one producer.
Since the previous matrix: matcher-rust hashes symbols with one multiply
instead of SipHash, matcher-go delivers events without allocating, Java's
bench sizes its heap for the 1.5 GB corpus and collects before measuring,
and every port writes CRC-sealed (version 2) journal records and keeps
stats counters.

| impl | matcher alone W4 | core W6 untimed | pipe P=1 off | best pipe off | pipe P=1 durable | best pipe durable |
|---|---|---|---|---|---|---|
| rust | 13.8M | 25.9M (was 11.7M) | 20.5M (was 15.8M) | 32.7M (P=3) | 8.7M | 20.6M (P=3) |
| cpp | 15.4M | 27.3M | 17.4M | 32.3M (P=3) | 6.5M | 18.3M (P=4) |
| java | 9.0M | 13.7M | 9.8M | 20.1M (P=2) | 7.4M | 14.7M (P=3) |
| go | 6.9M | 8.9M (was 6.4M) | 4.6M | 12.8M (P=4) | 3.8M | 13.6M (P=3) |
| ts | 5.1M | 3.8M | 4.1M | 7.6M (P=3) | 2.2M | 5.8M (P=4) |

Reading it:

- **Rust and C++ now match.** The symbol hasher doubled the Rust core on
  multi-symbol W6 (11.7M to 25.9M untimed), level with C++ (27.3M). Both
  pipelines reach about 32M commands/s with journals off and about 19–21M
  durable.
- **Java** gained most in its durable rows (best 9.4M to 14.7M), from
  sizing the heap for the corpus the bench holds live.
- **Go's core** is allocation-free now (`alloc_b_op=0`, 8.9M untimed). Its
  pipeline is the least stable at 10M commands: P=2 with journals off varies
  between 4.9M and 8.6M across runs, and P=4 durable stays near 5M while P=3
  durable reaches 13.6M. The P=4 drop needs fsync: the same row with
  journals but no fsync runs at 14.2M, and raising `GOMAXPROCS` to 16 does
  not help. **Open issue:** profile orderer-go's journal I/O goroutines
  under concurrent `F_FULLFSYNC`.
- **TypeScript** is bounded by its owner thread (egress decoding and plugs).
  Extra worker producers (`--producers N`, new in 0.2.0) do not raise it.
- **Durability is disk-bound here.** `orderbench --stats` (orderer-rust)
  shows `F_FULLFSYNC` averaging about 12 ms on this SSD, so a handful of
  group-committed fsyncs cover a million commands, and P=4 rarely beats
  P=3. `docs/SCALING.md` describes running the matrix on a Linux server
  with NVMe, which this machine cannot stand in for.

### Per-language rows

#### orderer-rust @ 2026-10-09 1c84158
env: Apple M1 / macos aarch64 / orderer-rust 0.2.0; W6 = 10000000 commands, 64 symbols
| workload | mode | P | prod | ops | ops/s | eff | mean | p50 | p90 | p99 | p99.9 | max | config |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| w4 | isolated | - | - | 1000000 | 13828517 |  | 46 | 41 | 125 | 291 | 583 | 14375 | matcher-rust matcherbench |
| w4 | core | - | - | 1000000 | 14402823 |  | 43 | 41 | 125 | 250 | 375 | 6583 | untimed=25139577 |
| w6 | core | - | - | 10000000 | 10785841 |  | 63 | 42 | 125 | 458 | 708 | 1156208 | untimed=25909714 |
| w6 | pipe | 1 | 1 | 10000000 | 20466378 | 0.79 | 1025327 | 971250 | 1211042 | 2160792 | 3898083 | 4618125 | journal=off fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 32110808 | 0.62 | 912583 | 902333 | 1046750 | 1500250 | 2462625 | 2899625 | journal=off fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 32694136 | 0.42 | 950494 | 876625 | 1336417 | 1754416 | 2465458 | 3278875 | journal=off fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 31583456 | 0.30 | 1014926 | 953291 | 1562417 | 2238000 | 3073333 | 4322709 | journal=off fsync=1024 |
| w6 | pipe | 1 | 1 | 10000000 | 8692206 | 0.34 | 2336512 | 2310541 | 2477125 | 3641708 | 5622875 | 6438917 | journal=binary fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 16030410 | 0.31 | 1392387 | 1342583 | 1709959 | 2713708 | 7554625 | 7887959 | journal=binary fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 20583886 | 0.26 | 1238561 | 1147250 | 1729000 | 2626250 | 3397875 | 3619375 | journal=binary fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 18994594 | 0.18 | 1491446 | 1397458 | 2058625 | 3739750 | 6961500 | 7737541 | journal=binary fsync=1024 |

#### orderer-cpp @ 2026-10-09 ba912a3
env: Apple M1 / orderer-cpp 0.2.0; W6 = 10000000 commands, 64 symbols
| workload | mode | P | prod | ops | ops/s | eff | mean | p50 | p90 | p99 | p99.9 | max | config |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| w4 | isolated | - | - | 1000000 | 15437846 |  | 47 | 41 | 125 | 292 | 750 | 12583 | matcher-cpp matcherbench |
| w4 | core | - | - | 1000000 | 11111728 |  | 69 | 42 | 167 | 375 | 750 | 3804584 | untimed=20563209 |
| w6 | core | - | - | 10000000 | 14351397 |  | 51 | 41 | 125 | 375 | 834 | 36667 | untimed=27348629 |
| w6 | pipe | 1 | 1 | 10000000 | 17437416 | 0.64 | 1155453 | 1124417 | 1234083 | 2529084 | 6895166 | 9306834 | journal=off fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 31569605 | 0.58 | 745990 | 699625 | 945250 | 1595583 | 3383958 | 4543916 | journal=off fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 32261204 | 0.39 | 855308 | 790750 | 1263541 | 1839292 | 3625084 | 3852000 | journal=off fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 31602641 | 0.29 | 984274 | 946666 | 1408417 | 1764125 | 2229250 | 2571500 | journal=off fsync=1024 |
| w6 | pipe | 1 | 1 | 10000000 | 6471221 | 0.24 | 3155519 | 3063458 | 3288500 | 5189375 | 19708375 | 21744708 | journal=binary fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 12552749 | 0.23 | 1774643 | 1783958 | 2020500 | 2981917 | 4579792 | 6099417 | journal=binary fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 16942122 | 0.21 | 1387603 | 1360583 | 1798959 | 2602041 | 3577750 | 4750125 | journal=binary fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 18276861 | 0.17 | 1460125 | 1366708 | 1979875 | 3598833 | 6793208 | 7314709 | journal=binary fsync=1024 |

#### orderer-java @ 2026-10-09 eaccbb3
env: Apple M1 / orderer-java 0.2.0 / java 20.0.1; W6 = 10000000 commands, 64 symbols
| workload | mode | P | prod | ops | ops/s | eff | mean | p50 | p90 | p99 | p99.9 | max | config |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| w4 | isolated | - | - | 1000000 | 8973080 |  |  | 42 | 250 | 583 | 1375 | 122042 | matcher-java matcherbench |
| w4 | core | - | - | 1000000 | 9874073 |  | 73 | 41 | 209 | 500 | 1833 | 38875 | untimed=20295759 alloc_b_op=12 |
| w6 | core | - | - | 10000000 | 9783058 |  | 84 | 42 | 250 | 542 | 834 | 222167 | untimed=13700072 alloc_b_op=24 |
| w6 | pipe | 1 | 1 | 10000000 | 9820783 | 0.72 | 2082482 | 1991458 | 2233500 | 5065583 | 7323916 | 8559583 | journal=off fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 20107378 | 0.73 | 1193962 | 1136292 | 1366542 | 2523375 | 4136416 | 4841375 | journal=off fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 17853243 | 0.43 | 1472898 | 1263416 | 1986834 | 4598584 | 41558625 | 42540208 | journal=off fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 16308301 | 0.30 | 1875837 | 1590708 | 2474375 | 5287292 | 39466792 | 40291083 | journal=off fsync=1024 |
| w6 | pipe | 1 | 1 | 10000000 | 7413370 | 0.54 | 2780351 | 2601792 | 3047750 | 6761875 | 20438166 | 20724834 | journal=binary fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 10589138 | 0.39 | 2136287 | 1927459 | 2568666 | 5117500 | 38466625 | 38780166 | journal=binary fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 14728787 | 0.36 | 1706426 | 1530667 | 2366584 | 3800084 | 22664500 | 23028541 | journal=binary fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 13954294 | 0.25 | 2086262 | 1900833 | 2826250 | 5046792 | 21724458 | 22592375 | journal=binary fsync=1024 |

#### orderer-go @ 2026-10-09 69d5efc
env: Apple M1 / orderer-go 0.2.0 / go1.27.1; W6 = 10000000 commands, 64 symbols
| workload | mode | P | prod | ops | ops/s | eff | mean | p50 | p90 | p99 | p99.9 | max | config |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| w4 | isolated | - | - | 1000000 | 6847058 |  | 106 | 84 | 208 | 416 | 625 | 26750 | matcher-go matcherbench |
| w4 | core | - | - | 1000000 | 6636348 |  | 112 | 125 | 208 | 416 | 584 | 23542 | untimed=12027115 alloc_b_op=0 |
| w6 | core | - | - | 10000000 | 5556316 |  | 143 | 125 | 250 | 500 | 834 | 163125 | untimed=8877529 alloc_b_op=0 |
| w6 | pipe | 1 | 1 | 10000000 | 4624981 | 0.52 | 4267079 | 3448875 | 4040541 | 39643291 | 62042083 | 66342417 | journal=off fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 4926521 | 0.28 | 4309760 | 1924333 | 7632542 | 38925583 | 66971417 | 88199584 | journal=off fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 11510594 | 0.43 | 1978571 | 1427542 | 2254375 | 14907625 | 69537292 | 82345666 | journal=off fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 12816114 | 0.36 | 1688484 | 1326542 | 2129833 | 8393125 | 25147917 | 42562250 | journal=off fsync=1024 |
| w6 | pipe | 1 | 1 | 10000000 | 3785650 | 0.43 | 5368349 | 4484417 | 5738708 | 22316041 | 91056334 | 120556166 | journal=binary fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 9288820 | 0.52 | 2276208 | 2270583 | 2760833 | 3321958 | 4531042 | 5278917 | journal=binary fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 13646103 | 0.51 | 1762430 | 1721833 | 2218792 | 2867750 | 5847541 | 6565792 | journal=binary fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 4950302 | 0.14 | 4379597 | 2184291 | 11873709 | 17858208 | 26393791 | 27706083 | journal=binary fsync=1024 |

#### orderer-ts @ 2026-10-09 ed4a387
env: Apple M1 / orderer-ts 0.2.0 / node v22.20.0; W6 = 10000000 commands, 64 symbols
| workload | mode | P | prod | ops | ops/s | eff | mean | p50 | p90 | p99 | p99.9 | max | config |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| w4 | isolated | - | - | 1000000 | 5139318 |  |  | 84 | 375 | 791 | 1166 | 465709 | matcher-ts matcherbench |
| w4 | core | - | - | 1000000 | 4467058 |  | 188 | 125 | 458 | 1000 | 1917 | 731666 | untimed=6534360 |
| w6 | core | - | - | 10000000 | 3056598 |  | 291 | 166 | 750 | 1541 | 3042 | 4881625 | untimed=3769701 |
| w6 | pipe | 1 | 1 | 10000000 | 4075859 | 1.08 | 4928982 | 4424795 | 5432104 | 10559717 | 82472651 | 90606198 | journal=off fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 5666940 | 0.75 | 4252848 | 3472483 | 6114635 | 13903987 | 81718381 | 95987628 | journal=off fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 7594007 | 0.67 | 4043690 | 3577240 | 5040230 | 10168588 | 71596616 | 89868860 | journal=off fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 7497301 | 0.50 | 4225030 | 3551527 | 5974335 | 12417092 | 76979574 | 106877108 | journal=off fsync=1024 |
| w6 | pipe | 1 | 1 | 10000000 | 2242888 | 0.59 | 8856373 | 8271377 | 9310740 | 20762705 | 87460760 | 97046124 | journal=binary fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 4281655 | 0.57 | 5172973 | 4948903 | 5736910 | 9881428 | 76041339 | 93346346 | journal=binary fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 5602370 | 0.50 | 4036595 | 3547295 | 4859675 | 9538701 | 73334282 | 96296330 | journal=binary fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 5835689 | 0.39 | 5453967 | 4881528 | 7420666 | 11101281 | 84284100 | 109795059 | journal=binary fsync=1024 |

## All five ports: isolated vs integrated (2026-10-08)

`COOLDOWN=5 scripts/bench.sh --n 10000000` on the same Apple M1 (4P+4E
cores, 16 GB, SSD 85% full), one producer. orderer-ts was rerun separately
after a loader fix (its 730 MB W6 corpus exceeded V8's string limit). Three
layers of each language's matching core:

- **matcher alone**: matcher-<lang>'s own `matcherbench` on W4 (single
  book, matcher's protocol, per-op clock reads).
- **core**: orderer `--mode core`, the same core as orderer embeds it.
  `untimed` is the eff baseline.
- **pipe**: the whole engine on W6 (64 symbols). `off` = no journals (rings,
  routing, egress); `durable` = the gated configuration (binary command
  journals, fsync every 1024 records).

| impl | matcher alone W4 | core W4 untimed | core W6 untimed | pipe P=1 off | pipe best off | pipe P=1 durable | pipe best durable | eff(4) durable |
|---|---|---|---|---|---|---|---|---|
| rust | 9.06M | 23.8M | 11.7M | 15.8M | 28.1M (P=3) | 10.2M | 21.8M (P=3) | 0.41 |
| cpp | 13.1M | 23.5M | 22.3M | 13.5M | 30.2M (P=3) | 8.8M | 22.8M (P=3) | 0.21 |
| java | 7.84M | 17.4M | 11.9M | 7.7M | 14.9M (P=4) | 6.9M | 9.4M (P=3) | 0.19 |
| go | 4.58M | 7.9M | 6.4M | 2.6M | 9.6M (P=4) | 3.6M | 7.4M (P=3) | 0.16 |
| ts | 4.81M | 5.9M | 3.7M | 3.7M | 7.0M (P=3) | 2.9M | 6.8M (P=3) | 0.42 |

All throughputs are ops/s. "matcher alone" is timed per operation (two
clock reads each), so compare it with the core rows' timed column below,
not with `untimed`. On that comparison, orderer's timed core W4 row matches
or beats matcher's own bench for Rust (10.7M vs 9.1M), C++ (13.3M vs
13.1M) and Java (9.8M vs 7.8M). Go is 3% below (4.46M vs 4.58M) and TS
12% below (4.23M vs 4.81M); neither gap is explained yet.

Reading it:

- **Native ports lead and converge.** Rust and C++ reach 28–30M with
  journals off and about 22M durable at P=3. Their cores differ by 1.9× on
  W6 (C++ 22.3M vs Rust 11.7M untimed; Rust's SipHash `HashMap` per symbol
  lookup is the likely cause). The pipelines land within 10% of each
  other, because the rings, routing and disk bound them, not the core.
- **Rust's pipeline at P=1 (15.8M, eff 1.35) beats its own core loop.**
  The pipeline moves event handling to the egress thread, so the engine
  thread does less per command than core mode's single loop. Not profiled.
- **Java** sits at half the native rate: 14.9M journals off, 9.4M durable.
  Its p99.9 of 95–216 ms on every pipe row are collector pauses.
  matcher-java allocates one record per event (`alloc_b_op` 24 on W6).
- **Go is the weakest integrated port.** P=1 with journals off (2.6M) is
  even slower than P=1 durable (3.6M), and p99/p99.9 run to 13–120 ms.
  matcher-go hands every event to its sink through an interface, so each
  one escapes to the heap (`alloc_b_op` 72). The collector then competes
  with goroutines that busy-spin on locked OS threads. Candidates: a
  non-escaping sink path in matcher-go, backoff instead of busy-spin for
  engines, and `GOGC` tuning. The core itself (6.4M) is fine.
- **TypeScript** scales from 3.7M to 7.0M across workers. The owner
  thread, which publishes and runs every egress plug, bounds it. Its
  `eff` (0.42 durable) is among the best, because the engines are not the
  bottleneck.
- **The durable gate (A4) is still not met by any port** on this machine.
  The phase-6 analysis below still applies: `F_FULLFSYNC` bandwidth on a
  nearly full SSD, and 4 performance cores shared by producer, router,
  engines, egress and I/O threads. P=4 is often below P=3 for the same
  reason.
- **Latency columns are open-loop saturation.** One producer publishes 10M
  commands as fast as ingress accepts, so the millisecond p50s are queueing
  delay, not service time.

### Per-language rows

#### orderer-rust @ 2026-10-08 d933299
env: Apple M1 / macos aarch64 / orderer-rust 0.1.0; W6 = 10000000 commands, 64 symbols
| workload | mode | P | prod | ops | ops/s | eff | mean | p50 | p90 | p99 | p99.9 | max | config |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| w4 | isolated | - | - | 1000000 | 9058108 |  | 83 | 42 | 208 | 542 | 1750 | 906542 | matcher-rust matcherbench |
| w4 | core | - | - | 1000000 | 10694377 |  | 66 | 42 | 167 | 417 | 750 | 56083 | untimed=23811697 |
| w6 | core | - | - | 10000000 | 5118690 |  | 159 | 84 | 250 | 666 | 1500 | 46834541 | untimed=11733020 |
| w6 | pipe | 1 | 1 | 10000000 | 15813207 | 1.35 | 1293088 | 1181958 | 1650375 | 2730333 | 4360209 | 4784667 | journal=off fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 27262049 | 1.16 | 839494 | 764291 | 1118916 | 2142000 | 3088458 | 3379791 | journal=off fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 28058627 | 0.80 | 1068133 | 998959 | 1352833 | 2727375 | 7899250 | 10045083 | journal=off fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 26860976 | 0.57 | 1179927 | 1135459 | 1627916 | 2456709 | 7792666 | 8723417 | journal=off fsync=1024 |
| w6 | pipe | 1 | 1 | 10000000 | 10199570 | 0.87 | 1950013 | 1646875 | 2414333 | 5192417 | 52319375 | 56295167 | journal=binary fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 19844097 | 0.85 | 1078785 | 928042 | 1532125 | 4303166 | 7617750 | 8084542 | journal=binary fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 21832556 | 0.62 | 1170940 | 1017917 | 1696750 | 4031542 | 8410542 | 10720792 | journal=binary fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 19385505 | 0.41 | 1476325 | 1287416 | 2076750 | 6249791 | 11081750 | 11911375 | journal=binary fsync=1024 |

#### orderer-cpp @ 2026-10-08 dbda998
env: Apple M1 / orderer-cpp 0.1.0; W6 = 10000000 commands, 64 symbols
| workload | mode | P | prod | ops | ops/s | eff | mean | p50 | p90 | p99 | p99.9 | max | config |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| w4 | isolated | - | - | 1000000 | 13070087 |  | 58 | 42 | 167 | 375 | 833 | 28292 | matcher-cpp matcherbench |
| w4 | core | - | - | 1000000 | 13305916 |  | 56 | 41 | 167 | 375 | 584 | 35041 | untimed=23477071 |
| w6 | core | - | - | 10000000 | 10868435 |  | 73 | 42 | 167 | 500 | 2792 | 182375 | untimed=22294692 |
| w6 | pipe | 1 | 1 | 10000000 | 13538367 | 0.61 | 1505551 | 1327042 | 1917458 | 3608541 | 13641875 | 16559208 | journal=off fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 26127454 | 0.59 | 878984 | 795875 | 1186875 | 2002375 | 3153834 | 3340208 | journal=off fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 30211579 | 0.45 | 862102 | 815334 | 1212125 | 1811500 | 2732166 | 3465292 | journal=off fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 27537014 | 0.31 | 1016792 | 970334 | 1413042 | 1988917 | 3555375 | 4321000 | journal=off fsync=1024 |
| w6 | pipe | 1 | 1 | 10000000 | 8812342 | 0.40 | 2326310 | 2073083 | 3118334 | 5635958 | 8158625 | 8717291 | journal=binary fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 17571037 | 0.39 | 1272538 | 1178583 | 1708250 | 2524541 | 4306584 | 6193334 | journal=binary fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 22812216 | 0.34 | 1085099 | 984292 | 1586333 | 2796083 | 3845459 | 4763459 | journal=binary fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 18441164 | 0.21 | 1426008 | 1135500 | 2053958 | 8561625 | 15328416 | 15919750 | journal=binary fsync=1024 |

#### orderer-java @ 2026-10-08 26bdeb5
env: Apple M1 / orderer-java 0.1.0 / java 20.0.1; W6 = 10000000 commands, 64 symbols
| workload | mode | P | prod | ops | ops/s | eff | mean | p50 | p90 | p99 | p99.9 | max | config |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| w4 | isolated | - | - | 1000000 | 7841705 |  |  | 42 | 292 | 708 | 2292 | 83666 | matcher-java matcherbench |
| w4 | core | - | - | 1000000 | 9798814 |  | 74 | 42 | 250 | 459 | 750 | 69292 | untimed=17442418 alloc_b_op=12 |
| w6 | core | - | - | 10000000 | 8426327 |  | 102 | 42 | 291 | 666 | 1167 | 148959 | untimed=11880784 alloc_b_op=24 |
| w6 | pipe | 1 | 1 | 10000000 | 7734826 | 0.65 | 2656032 | 2278375 | 2959166 | 5271958 | 96577334 | 96764792 | journal=off fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 11847425 | 0.50 | 1906924 | 1367042 | 2020166 | 3741542 | 162983125 | 163989334 | journal=off fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 12797677 | 0.36 | 1850084 | 1232417 | 2031000 | 4880750 | 201030333 | 202002208 | journal=off fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 14889754 | 0.31 | 1737838 | 1391333 | 2089792 | 3124708 | 132466458 | 133503833 | journal=off fsync=1024 |
| w6 | pipe | 1 | 1 | 10000000 | 6892582 | 0.58 | 2957670 | 2568834 | 3231583 | 6274417 | 111493708 | 111676166 | journal=binary fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 9257314 | 0.39 | 2452353 | 1735000 | 2618291 | 5808583 | 215807417 | 216083917 | journal=binary fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 9387348 | 0.26 | 2454737 | 1658417 | 3218625 | 7414084 | 130905958 | 132481875 | journal=binary fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 9169806 | 0.19 | 2453200 | 1761167 | 3100917 | 8590000 | 94936167 | 180018958 | journal=binary fsync=1024 |

#### orderer-go @ 2026-10-08 0c4d9ff
env: Apple M1 / orderer-go 0.1.0 / go1.27.1; W6 = 10000000 commands, 64 symbols
| workload | mode | P | prod | ops | ops/s | eff | mean | p50 | p90 | p99 | p99.9 | max | config |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| w4 | isolated | - | - | 1000000 | 4578693 |  | 179 | 125 | 334 | 708 | 3250 | 145084 | matcher-go matcherbench |
| w4 | core | - | - | 1000000 | 4463091 |  | 185 | 125 | 334 | 750 | 2583 | 273083 | untimed=7893262 alloc_b_op=80 |
| w6 | core | - | - | 10000000 | 4589209 |  | 181 | 166 | 292 | 708 | 1708 | 164500 | untimed=6437434 alloc_b_op=72 |
| w6 | pipe | 1 | 1 | 10000000 | 2592462 | 0.40 | 7901503 | 4548625 | 11315500 | 72714834 | 119391292 | 135786917 | journal=off fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 7413553 | 0.58 | 2924677 | 2246167 | 3217916 | 12824875 | 81126958 | 110041625 | journal=off fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 7577757 | 0.39 | 2878785 | 1715333 | 4005416 | 22986666 | 65861875 | 101939042 | journal=off fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 9560923 | 0.37 | 2804378 | 2274042 | 3926791 | 13501334 | 51654625 | 91706709 | journal=off fsync=1024 |
| w6 | pipe | 1 | 1 | 10000000 | 3576786 | 0.56 | 5704249 | 4796750 | 5739667 | 35965625 | 86333792 | 97361292 | journal=binary fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 6277503 | 0.49 | 3465252 | 2769209 | 4389208 | 14391333 | 50887417 | 67234792 | journal=binary fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 7379936 | 0.38 | 3209332 | 1981750 | 3638875 | 27991459 | 69616334 | 87961125 | journal=binary fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 4157626 | 0.16 | 5251705 | 3322333 | 11707042 | 20145250 | 120981708 | 123890917 | journal=binary fsync=1024 |

#### orderer-ts @ 2026-10-08 1d7db6e
env: Apple M1 / orderer-ts 0.1.0 / node v22.20.0; W6 = 10000000 commands, 64 symbols
| workload | mode | P | prod | ops | ops/s | eff | mean | p50 | p90 | p99 | p99.9 | max | config |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| w4 | isolated | - | - | 1000000 | 4809577 |  |  | 125 | 417 | 834 | 1334 | 534167 | matcher-ts matcherbench |
| w4 | core | - | - | 1000000 | 4233532 |  | 200 | 125 | 459 | 1041 | 1750 | 1048208 | untimed=5919183 |
| w6 | core | - | - | 10000000 | 2870342 |  | 311 | 166 | 791 | 1708 | 3625 | 4926625 | untimed=3708138 |
| w6 | pipe | 1 | 1 | 10000000 | 3728152 | 1.01 | 5455755 | 4934375 | 6348500 | 11857333 | 89463042 | 99010458 | journal=off fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 6210839 | 0.84 | 3663067 | 2964583 | 4949958 | 11514500 | 83676959 | 102450250 | journal=off fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 6969472 | 0.63 | 4445683 | 3768708 | 5402000 | 21464792 | 86079000 | 111848791 | journal=off fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 6648530 | 0.45 | 5025698 | 4336834 | 6900750 | 23638500 | 67540500 | 89494042 | journal=off fsync=1024 |
| w6 | pipe | 1 | 1 | 10000000 | 2875472 | 0.78 | 7039497 | 6299958 | 8820000 | 15583208 | 92094334 | 103534334 | journal=binary fsync=1024 |
| w6 | pipe | 2 | 1 | 10000000 | 5517783 | 0.74 | 4077161 | 3426708 | 4690500 | 15563959 | 87523500 | 105890333 | journal=binary fsync=1024 |
| w6 | pipe | 3 | 1 | 10000000 | 6825474 | 0.61 | 4545748 | 4057459 | 5817541 | 9560791 | 86670208 | 127530792 | journal=binary fsync=1024 |
| w6 | pipe | 4 | 1 | 10000000 | 6162007 | 0.42 | 5381182 | 4660875 | 7514667 | 11668750 | 87706083 | 106665875 | journal=binary fsync=1024 |

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
