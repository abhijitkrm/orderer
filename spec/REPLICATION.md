# REPLICATION — replicated ingress log and failover (DRAFT v0.1)

**Status: draft, not yet part of any tagged spec.** Nothing here is
implemented. It is written to be argued with before code exists. Open
decisions are marked **[DECIDE]** and collected in §11.

Extends `PIPELINE.md` and `JOURNAL.md`. Matching semantics stay matcher's
and are not restated.

---

## 1. Goal and non-goals

**Goal.** Survive the loss of a minority of nodes with no acknowledged
command lost, no command applied twice, and no divergence between nodes.
Failover completes without operator action.

**Why this fits.** The pipeline is already a deterministic state machine:
the same command sequence yields byte-identical events and snapshots in all
five ports. Replication therefore reduces to agreeing on **one totally
ordered command log**. Every node applies the same log and must reach the
same state.

**Non-goals (v1).**
- Dynamic membership. The node set is static configuration.
- Byzantine faults. Nodes crash, restart, lose messages and lose the tail
  of a file. They do not lie.
- Cross-datacenter tuning, leader leases for reads, and client sessions
  (step 2: wire protocol).
- More than one replicated group per pipeline (see §11, D1).

## 2. Model

```
producers ─▶ LEADER sequencer ─▶ replicated ingress log ─▶ commit
                                    │  append (term, iseq, cmd)
                         FOLLOWERS ◀┘  persist, then ack
commit ─▶ router ─▶ partitions ─▶ engines ─▶ egress     (on every node)
```

- A cluster has `N = 2f + 1` nodes (`N = 3` typical, tolerates `f = 1`).
  `N = 1` is valid and is the degenerate case: it behaves exactly like
  today's pipeline.
- Exactly one node is **leader** in a given **term**. Only the leader
  accepts producers and assigns `iseq`.
- The **ingress log** is the replicated object: a sequence of control and
  command entries in ingress order. This is the existing ingress order of
  `PIPELINE.md` §2, made durable and shared.
- Each node runs the unchanged pipeline *after* the log: router, partition
  engines, egress. Partition command journals stop being the source of
  truth in replicated mode (§6).

## 3. Log entries and terms

An entry is `(term, index, payload)`.

- `index` is the log position, 1-based and dense. For command entries
  `index` equals `iseq`. Control operations (`PIPELINE.md` §6) are entries
  too, so with controls present `index ≥ iseq`. **[DECIDE D5]** whether
  controls get their own `iseq`-free index or the log uses `index` only.
- `term` (u32) is the election epoch in which the leader created the entry.
- **Log matching.** If two logs hold an entry with the same `(index, term)`,
  the two logs are identical up to and including that index.
- **Binary record.** The 48-byte command record of `JOURNAL.md` §2.2
  version 2 has 4 reserved bytes at offset 44. Version 3 stores `term` there
  and extends the CRC-32C to bytes 0–39 plus 44–47. Control entries use
  `cmd = 0x10..0x1F` and the same record size.

## 4. Commit and apply

- An entry is **committed** once it is persisted (fsync completed) on a
  majority of nodes **in the leader's current term or earlier, with the
  Raft safety rule**: a leader commits entries from earlier terms only
  indirectly, by committing an entry of its own term after them.
- `commit_index` is monotone on every node and never moves backward.
- **Apply is gated by commit, not by local write.** This replaces the gate
  in `PIPELINE.md` §4 (`journaled_iseq` gates the engine) when `N > 1`:
  the engine applies entry `i` only when `commit_index ≥ i`. With `N = 1`,
  commit coincides with the local write, so §4 holds unchanged.
- Consequence: **no state is ever rolled back.** A node only applies
  committed entries, and committed entries are never lost, so there is no
  undo path to build or test. Uncommitted log tails may be truncated and
  rewritten; applied state may not.
- **Ack contract.** `durable_iseq` of `PIPELINE.md` §5 is redefined for
  `N > 1` as the highest `iseq` with `commit_index ≥ index`. An ack is
  therefore released only after a **quorum** has the command durable.
- **Cost.** Latency to ack is one network round trip plus a remote fsync,
  added to today's. This is inherent; the design batches (§9) to keep
  throughput.

## 5. Elections and fencing

- Raft-style: randomized election timeouts, `RequestVote` with the
  up-to-date check `(last_term, last_index)` lexicographic, one vote per
  term, persisted before replying.
- `term` and `voted_for` are persisted in a small metadata file with the
  same CRC and torn-write discipline as journals.
- **Fencing.** Every message carries the sender's term. A node rejects any
  message from a lower term. A deposed leader that learns of a higher term
  stops publishing immediately: later `publish` fails with a *not-leader*
  error carrying a leader hint. Nothing in flight is acknowledged after
  that, because acks require commit.
- A new leader appends a no-op entry in its term before accepting
  producers, which both commits earlier entries and establishes its
  authority.
- **Pre-vote** is required, so a partitioned node cannot inflate terms and
  depose a healthy leader on rejoin. **[DECIDE D4]**: whether pre-vote is
  v1 or v1.1.

## 6. Recovery, snapshots and catch-up

- On restart a node reads its metadata and ingress log, truncating any torn
  tail (`JOURNAL.md` §5.2), and rejoins as follower. It does not apply
  anything until it learns `commit_index`.
- **Checkpoints** (`JOURNAL.md` §6) keep their meaning: a durable snapshot
  at cut `N` allows deleting earlier segments. In replicated mode a
  checkpoint may only be taken at a cut ≤ `commit_index`.
- **Catch-up.** A follower whose needed prefix was already deleted receives
  the leader's latest snapshot, then the log suffix. Snapshot transfer is
  chunked, CRC-checked, and restartable.
- **State divergence detection.** At every checkpoint each node computes a
  SHA-256 over the canonical snapshot bytes (`matcher` `JOURNAL.md` §4,
  already byte-identical across ports) and sends `(cut, digest)` to the
  leader. A mismatch is a bug, not a recoverable fault. The mismatching node
  halts (fail-stop), the cluster keeps running if a quorum still agrees, and
  the event is surfaced loudly.

## 7. Egress and consumers

- Every node derives events deterministically. Only the **leader's** egress
  is live toward external consumers; followers run egress in
  discard-or-local mode.
- After a failover the new leader re-emits from its own applied state.
  Consumers de-duplicate on `(symbol, seq)`, which is dense per book and
  already part of the event contract (`PIPELINE.md` §7). This gives
  effectively-once delivery with no extra protocol.

## 8. Failure semantics (what a client can rely on)

| Situation | Guarantee |
|---|---|
| Leader crashes after the client got an ack | Command is committed on a quorum; the new leader applies it. Never lost. |
| Leader crashes before ack | Command may or may not be committed. The client does not know. Resolving this needs client-ID dedupe (step 2); the log carries what that needs. |
| Minority partition | Minority side cannot commit and refuses publishes; majority side continues. |
| Leader loses quorum | It stops acking and steps down after a timeout. |
| Follower loses disk tail | It truncates, catches up from leader. Cannot affect committed state. |
| Two nodes disagree on state | Impossible if deterministic; detected by §6 digests; offender halts. |

## 9. Performance expectations (to be measured, not assumed)

- A 48-byte entry at 30M entries/s is ~1.4 GB/s per follower link. A single
  replicated log therefore **bounds aggregate throughput by network and
  follower fsync bandwidth**, not by the cores. This is the design's main
  trade-off (D1).
- Mitigation: batch entries per message (target ≥ 4 KiB), pipeline
  `AppendEntries` without waiting for each ack, group-commit fsync on
  followers, and compress nothing (cost exceeds benefit at this size).
- Replication throughput targets must be measured on Linux with NVMe and a
  real NIC. The M1 numbers in `docs/RESULTS.md` are not valid for this
  (F_FULLFSYNC ~12 ms).

## 10. Verification plan (this is where the work is)

Writing consensus is the risky part, so correctness evidence comes first.

1. **Pure protocol core.** The protocol is a function: `(state, input) →
   (state', effects)`. Inputs: message received, timer fired, disk write
   completed, client proposal. Effects: send message, start disk write,
   set timer, apply entries. It performs no I/O and reads no clock.
2. **Deterministic simulation.** A single-threaded harness drives N cores
   with a seeded PRNG controlling: message drop / duplicate / reorder /
   delay, partitions, node crash and restart, torn and lost disk tails,
   slow or failing fsync, clock skew. It checks, after every step:
   - election safety: at most one leader per term;
   - log matching and leader completeness;
   - **committed prefix identical** on all nodes, never shrinking;
   - no entry applied twice, none applied before commit;
   - every acked command is in every later leader's log;
   - applied state digests equal at equal `commit_index`.
   Any failure prints the seed and replays exactly.
3. **Cross-port conformance.** The seeded input traces and expected effect
   traces become vectors in `vectors/replication/`. Every port's protocol
   core must produce byte-identical effects for the same input trace, the
   same technique already used for matching. This is how five ports stay
   consistent without five independent consensus bugs.
4. **Real-process failover test.** Extend `scripts/crash.sh`: kill -9 the
   leader under load, repeatedly, and check no acknowledged command is lost
   and all survivors' snapshots are identical.

## 11. Open decisions

- **D1 one log vs one log per partition.** *Recommendation: one log.* It
  preserves the total ingress order that barriers and snapshot cuts rely on
  (`PIPELINE.md` §6), and keeps recovery simple. Cost: replication bandwidth
  caps aggregate throughput (§9). Per-partition groups scale better but lose
  global cuts; revisit only if measurements show the cap matters.
- **D2 apply after commit** (recommended, §4) vs leader applies after local
  write and followers after commit. The latter lowers leader latency but
  needs a rollback path on leader change; rejected for v1.
- **D3 build vs reuse.** Implement the protocol core ourselves (needed for
  five ports and byte-level conformance vectors) vs wrap an existing
  library per language. *Recommendation: build, with the §10 tests as the
  justification for trusting it.*
- **D4 pre-vote in v1** (recommended) or later.
- **D5 control entries and `iseq`.** Separate index space vs shared (§3).
- **D6 static membership** for v1 (recommended).

## 12. Phasing

| Phase | Deliverable |
|---|---|
| R-A | This spec accepted; message wire format and vector format fixed |
| R-B | `orderer-rust`: pure protocol core + deterministic simulator, all §10.2 invariants green over a large seed sweep |
| R-C | Integrate: ingress log, commit-gated apply, `N = 1` regression-identical to today |
| R-D | TCP transport, snapshot transfer, real 3-node run |
| R-E | Failover under load (kill -9), digest checks, BENCH numbers on Linux |
| R-F | Ports: C++, Java, Go, TS against `vectors/replication/` |
