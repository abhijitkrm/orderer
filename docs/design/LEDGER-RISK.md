# Proposal: ledger and pre-trade risk

Status: **decided; roadmap step 1 is implemented** in `orderer-rust/crates/orderer-ledger`
(section 12). Sections 2-10 describe the design; later steps are not built. Read
`COMMAND-FORMAT.md` first: this design relies on its account sidecar, leader
timestamps and ledger-assigned order ids. Decisions that need an answer are
collected in section 11.

## 1. What has to be true

A venue that handles millions of accounts and billions of trades a day must:

- never let an account spend what it does not have, **even under concurrent
  orders, retries, crashes and failovers**;
- conserve money: for every asset, the sum of all balances never changes except by
  deposits, withdrawals and fees, and any bug that breaks it is detected;
- apply every fill to the two accounts involved **exactly once**, though matching
  and balances live in different replicated groups;
- keep the order path short, because for HFT every serial replicated hop costs
  tens of microseconds;
- be auditable and replayable.

Scale: a billion trades a day is about 12K trades/s on average and perhaps
100-500K/s at peak. Millions of accounts at a few assets each is single-digit
gigabytes of balance state in total, spread over shards. The matching tier already
has 30x headroom over this (REPLICATION 13.12). The hard parts are correctness
and the order path, not raw throughput.

## 2. The shape

```
 gateways (stateless: sessions, auth, rate limits)
     |  order, cancel                         accounts: sharded by hash(account)
     v
 LEDGER groups L0..Lm   <- deposits, withdrawals, fees
  (replicated; hold balances, reserve funds, assign order ids)
     |  Submit(order)  (outbox, exactly once)
     v
 MATCHING groups M0..Mn  (replicated; sharded by symbol; the existing runtime)
     |  committed event stream (ordered, archived)
     v
 SETTLERS  (stateless routers)  --Settle(event)-->  LEDGER groups
     |
     +--> market data feed, execution reports, audit
```

Both tiers are replicated state machines on the runtime we already have, and use
the facility we already have for exactly-once between them: sessions (a client id
and a sequence number, deduplicated inside the state machine).

## 3. The ledger state machine

State, per ledger shard: for each account, for each asset, `available` and `held`
(integers in the asset's smallest unit, 128-bit; no floating point anywhere), plus
an open-order table `order_id -> (account, asset held, amount held, remaining qty)`,
a per-shard order counter, and the dedup marks of section 5.

Commands (each is one log entry, idempotent under the session or the marks):

| Command | Effect |
|---|---|
| `Deposit(account, asset, amount, external_id)` | `available += amount`, once per `external_id` |
| `Reserve(account, symbol, side, price, qty, tif)` | check funds, move them `available -> held`, assign the next order id, write the open order, queue a `Submit` in the outbox; reject if funds are short |
| `CancelRequest(account, order_id)` | check ownership, queue a cancel in the outbox |
| `Settle(source, idx, event)` | apply a matching event (section 5), once |
| `WithdrawRequest / WithdrawFinalize` | reserve, then pay out externally, then finalize or release |
| `Adjust(...)` | administrative, with a reason, always logged |

What `Reserve` holds: a **buy** limit order holds `price x qty` of the quote asset;
a **sell** holds `qty` of the base asset. A market buy has no limit price, so it
needs a bound the venue defines (a protection price, or a notional cap); that is an
open decision (section 11).

## 4. The order path, phase 1: reserve, then match (two hops)

1. Gateway sends `Reserve` to the account's ledger shard. The shard commits it
   (one replicated hop) and replies with the order id or a rejection.
2. The commit also wrote a `Submit(order)` into the shard's **outbox**, part of its
   replicated state. A forwarder delivers outbox entries to the symbol's matching
   group through a session whose client id is the ledger shard and whose sequence
   number is the outbox index. Delivery is at least once; the matching group
   deduplicates by session, so the order enters its log **exactly once**, even if
   the forwarder crashes and resends or the ledger fails over.
3. Matching processes the order and emits events as it does today.

This is simple and its correctness argument is local to each tier. Its cost is two
serial replicated hops before an order rests in a book. Section 8 removes one.

## 5. Settlement: exactly once without a distributed transaction

A trade involves two accounts, usually on different ledger shards, and a matching
group that knows neither. There is no two-phase commit. Instead:

- A **settler** reads each matching group's committed event stream in order
  (from the event archive, with a stored cursor). For each event it finds the ledger
  shards involved **from the order ids alone** (the shard is in the high bits,
  COMMAND-FORMAT D3), and sends `Settle(source, idx, event)` to each, through a
  session, at least once.
- A ledger shard keeps, per matching group, the highest event index it has applied
  (`hw[source]`). `Settle` with `idx <= hw[source]` is a duplicate and is ignored;
  otherwise it is applied and `hw` advances. **Amended in step 2:** a mark alone is
  only safe if events arrive in order, and a session guarantees order only for a
  stop-and-wait sender. So every settle also carries `prev`, the index of the
  previous event of that stream routed to the shard, and is applied only if `prev`
  equals the shard's mark (else it is refused as a gap and nothing changes). Order,
  loss, duplication and zombie senders then cannot skip an event.

Effects on the shard, per event:

| Event | Effect on this shard's account |
|---|---|
| Trade, as buyer | `held[quote] -= price_limit_hold_for_this_fill`; `available[quote] += (limit hold - trade value)` (price improvement); `available[base] += qty`; fee deducted |
| Trade, as seller | `held[base] -= qty`; `available[quote] += trade value`; fee deducted |
| Closed (cancelled, expired, filled with remainder) | release what is still held for the order |
| Rejected | release the whole hold |
| Replaced | adjust the hold (more funds, or release the difference) |

Fees go to a fee account in the same shard's accounting (a per-asset system account),
so conservation holds without special cases.

## 6. Invariants

- **I1 conservation.** For each asset, the sum over every shard of `available + held`
  over all accounts plus fee and system accounts equals deposits minus withdrawals.
- **I2 no overdraft.** No `available` or `held` is ever negative.
- **I3 holds match orders.** `held` equals the sum of the open orders' remaining holds.
- **I4 exactly once.** A given `(source, idx)` changes balances at most once.
- **I5 liveness.** Every accepted order ends as filled, cancelled or rejected, and its
  hold is released; a reconciler finds holds with no progress and cancels them.

I1-I4 are checked after every step in the simulator (section 9) and continuously by
an audit process that reads the ledger logs.

## 7. Failure cases

| Failure | Why it is safe |
|---|---|
| Gateway crashes after `Reserve` | the outbox, not the gateway, delivers; the client retries `Reserve` by session and gets the same order id |
| Forwarder crashes or resends | the matching group dedups by session |
| Ledger shard fails over | the new leader has the same replicated outbox and marks |
| Matching group fails over | the event stream and archive offsets are replicated state; settlers resume from their cursors |
| Settler crashes or resends | `hw` marks make a replay a no-op |
| An order is stuck (no event arrives) | I5 reconciler cancels it after a timeout |
| A bug breaks conservation | I1 audit detects it; the simulator is meant to find it first |

## 8. Phase 2: delegated credit slices (one hop)

For HFT the second hop is the cost to remove. The idea: a matching group is given,
per account and asset, a **slice** of that account's balance (a standing reservation
made by the ledger, delivered through the same exactly-once path). The matching
group's state machine then does the pre-trade check **locally**: an array lookup
against the slice, no ledger round trip. Settlement of trades between two accounts
that both hold slices in this group is also local and atomic with matching. The
ledger learns net movements asynchronously, in batches, with the same `(source,
idx)` marks, and tops slices up or recalls them (for a withdrawal or a rebalance)
through sequenced messages.

This changes where `Reserve` executes, not the ledger data model or the invariants
(a slice is a standing hold). Its cost is real complexity: slice sizing, refill and
recall protocols, and an account that suddenly trades in many groups. It should
come after phase 1 is proven in the simulator, not before.

## 9. Verification plan

1. Extend the deterministic simulator to a whole-system model: ledger groups,
   matching groups, a settler, a forwarder, with message loss, duplication,
   reordering and crashes of every role. Check I1-I4 after every step.
2. Mutation testing, as for the protocol core: remove the `hw` check, the ownership
   check, the hold release on `Closed`, the fee entry; the simulator must fail each.
3. Property tests on the ledger state machine alone: random command streams,
   conservation and non-negativity at every step, replay equals original.
4. Mixed-language is not a goal here: the ledger is built once, in Rust, and exposes
   the wire formats; other languages can be clients.
5. Real processes under `kill -9`, as `scripts/failover.sh` does today, with the
   audit process running.

## 10. Roadmap

1. Money types and the `LedgerSm` state machine, single shard, with the property
   tests (no networking). This is the part that must be right.
2. Outbox and forwarder, the settler, and the whole-system simulator with
   mutations.
3. Sharding by account, the gateway, the audit process, real-process failure tests.
4. Fees, withdrawals, the reconciler.
5. Phase 2 credit slices, once the above is solid.

## 11. Decisions needed from you

1. **Phase 1 first, phase 2 later?** I recommend it: correctness and the simulator
   first, then the latency optimization. If the latency target is hard from day one,
   say so and I would design the slice protocol up front.
2. **Market orders.** What bounds a market buy's hold: a protection price, a
   notional cap, or reject market buys without a limit?
3. **Which products.** Spot only (this document) or also margin and derivatives?
   The latter needs positions, mark prices, margin rules and liquidation, which is a
   separate design built on the same ledger.
4. **Amounts.** 128-bit integers in smallest units, per-asset decimals in reference
   data. Any asset with a precision this cannot hold?
5. **Who runs deposits and withdrawals?** The ledger exposes idempotent commands;
   the external payment or blockchain integration is outside this design.

## 12. Decisions taken and what is built

Decisions (the recommendations in section 11 were accepted):

1. **Phase 1 first** (reserve, then match). Credit slices (phase 2) come after the
   simulator and real-process tests are solid.
2. **Market buys carry a protection price**; the ledger holds `price x qty` like any
   limit order. A buy with no price is rejected (`BadPrice`).
3. **Spot only.** Margin and derivatives are a separate design on the same ledger.
4. **Amounts** are `u128` atoms; a symbol has `lot` base atoms per quantity unit and a
   price in quote atoms per lot, so every product is an exact integer. Overflow rejects.
5. **Deposits and withdrawals** are idempotent ledger commands keyed by external id;
   the payment integration is outside the ledger.
6. Self-trade prevention is not in the first release (it needs a matcher change).
   Leader-stamped time is not used by the ledger yet.

Step 1, as built (`orderer-ledger`): `Ledger` (pure, no I/O) and `LedgerSm` (adapter to
the replication runtime); commands Deposit, Reserve, Cancel, Settle, Withdraw,
Finalize, OutboxAck with a fixed little-endian wire format (golden bytes pinned);
canonical snapshot and SHA-256 digest; `Ledger::check()` for the invariants.

Refinements found while building it:

- **I1 is per shard only with trade flows counted.** A trade moves value between
  shards, so a single shard satisfies `holdings + withdrawn + settled_out =
  deposited + settled_in`, and the plain statement "sum of balances = deposits minus
  withdrawals" holds across all shards only once every event has been settled on every
  shard involved. Both forms are checked.
- **Contradictory events are anomalies, not panics.** A trade outside a limit, larger
  than the remainder, or for an unknown order changes no balance, advances the mark (a
  replay must not retry it) and is counted; `check()` fails while the count is non-zero.
- **Order-hold exactness (I3):** each open order holds exactly `price x remaining`
  (buy) or `lot x remaining` (sell); `check()` verifies that, not just the sums.
- `Rejected` and `Replaced` events are not modelled: a rejection is a `Closed`, and
  replace is later work.

Verification so far: 15 unit tests and 3 property tests (60 seeds x 1,500 steps each on
1 and 3 shards, with duplicated and delayed delivery, a price-time matching model, IOC
orders, cancels by non-owners, withdrawals, snapshot restore and full-log replay, and a
final conservation and hold-release check). Eight deliberately injected bugs (weakened
mark check, no ownership check, no release on close, no fee booking, no price
improvement refund, no funds check, non-idempotent deposit, no hold on withdrawal)
were each caught.

## 13. Step 2: relays and the whole-system simulator

Built (`orderer-ledger`, `src/flow.rs`, `tests/system.rs`):

- **Outbox to matching.** Outbox indices are contiguous, so the matching group's
  `Intake` (replicated, in its snapshot) accepts a message only if its index is
  exactly the next one for that ledger shard; lower is a duplicate, higher a gap.
  This replaces "dedup by session" for this path: sessions skip sequence gaps, so a
  pipelined message lost before a later one would be lost for good. The reply carries
  the cursor; a `Forwarder` with no memory recovers from it (go-back-N) and the
  cursor becomes `OutboxAck`, which trims the ledger's outbox.
- **Settle chain.** `Cmd::Settle` gained `prev` (above). `settle_cmds(source, shard,
  hw, stream, max)` builds the chain; a settler restarts by reading the shard's mark,
  so its own memory (including its read position) is disposable. It scans the whole
  stream per shard; an index by shard is a later optimisation.
- Neither relay has durable state of its own. A crashed forwarder or settler is simply
  a new one.

Simulator: clients, 1 or 3 ledger shards, forwarders, a price-time matching group
with IOC orders, and settlers, over a network that drops 8%, duplicates 7% and
reorders freely, with crashes of forwarders and settlers and ledger failover (state
restored from a snapshot, half the in-flight messages lost). Checked at every step:
every shard's `check()`; the intake applies exactly the ledger's outbox, in order,
with identical content; each shard applies exactly the events it is owed, in order,
once; marks never go backwards. After faults stop, within a bounded number of rounds:
all outboxes delivered and trimmed, all marks at the end of their streams. Then every
order is cancelled and drained again, and money is conserved across shards, no hold
is left, ledger orders equal resting orders, and each log replays to its state.

Measured on 80 seeds of 3,000 steps (plus 10 for the fault census): 1.7K drops, 1.5K
duplicates, 722 role crashes, 183 failovers, 620 settles refused as gaps, 3.2K intake
gap refusals; no violation.

Mutation testing: removing the `prev` check, letting intake skip gaps, letting it
accept duplicates, acking what was sent rather than what was accepted, and using a
wrong `prev` in the settler were each caught by the simulator; a mark that stalls on
an anomaly and an unclamped ack by unit tests (the simulator's matching model never
contradicts the ledger). Not caught, by design: dropping the go-back on a gap reply;
it is only a latency optimisation, the timeout rewind provides liveness.

Not yet done: real transport and processes (a gateway, `kill -9` runs), the audit
process, sharding of gateways, the reconciler for stuck orders (I5 is shown here only
with all roles eventually healthy), and an on-wire form of the matching-side intake
(it must live in the matching group's state machine alongside the command-format
sidecar).

## 14. Step 4: time, reconciler, fees, adjustments

Built in `orderer-ledger` (same crate, `LDG2` snapshots):

- **Clock.** `Clock { now_ns }` (tag 8) is the only source of time in the state
  machine; it only moves forward. Orders record `born` (the clock at reserve) and
  `cancel_at`. Replicas therefore agree on every age. The clock is meant to be fed
  by the leader-stamped timestamps of COMMAND-FORMAT; here it is a command.
- **Reconciler.** `Sweep { max_age_ns, retry_ns, max }` (tag 9) queues a `Cancel`
  to the outbox for open orders older than `max_age_ns` that have none queued, and
  re-queues one when it was queued at least `retry_ns` ago (0 = never), at most
  `max` per sweep, scanning in order-id order. **It never releases a hold.** Only a
  matching event may, because the order might still be live; the simulator asserts
  that no order resting in matching is ever absent from its ledger. A re-sent cancel
  is harmless: it is a new outbox index (so intake accepts it) and matching treats
  the cancel of an order that is not resting as a no-op. What the sweep guarantees
  is I5 for abandoned orders (the client or gateway is gone): the order is cancelled
  at matching and its `Closed` event releases the hold. What it cannot do is end a
  hold whose `Closed` is stuck behind a stalled settler; the hold stays, safely,
  until the stream flows again. The scan is O(open orders) per sweep (an age index
  is later work).
- **Fees.** `Config.fees` gives a `(maker_ppm, taker_ppm)` per symbol, falling back
  to `fee_ppm` for both. `Event::Trade` gained `taker_is_buy` (the aggressor), so the
  maker and the taker pay their own rate on what each receives, floored. Fees accrue
  to a pool per asset (the system account `FEE_ACCOUNT = u64::MAX`, which no user
  command may name: `Reject::ReservedAccount`). `FeeWithdraw` (tag 11) moves fees
  into the existing pending-withdrawal table; `Finalize` pays them out or returns
  them to the pool. Withdrawal ids are one namespace for users and fees.
- **Adjustments.** `Adjust { account, asset, amount, credit, reason, external_id }`
  (tag 10) is idempotent by `external_id` (a rejected one does not consume its id),
  can never take `available` below zero, and is counted in conservation:
  `holdings + withdrawn + settled_out + adjusted_out = deposited + settled_in +
  adjusted_in`. The newest 256 adjustments (id, account, asset, direction, amount,
  reason) are kept in a bounded ring in the state, in snapshots and in the digest;
  the log of commands is the complete audit trail.

Wire changes (all other layouts unchanged; Reserve's golden bytes are untouched):
new command tags 8-11; the trade event (kind 1 inside `Settle`) ends with a
`taker_is_buy u8` (0 or 1, anything else is refused); snapshots are `LDG2` and add
the clock, per-order `born` and `cancel_at`, the adjustment ids, flows and ring.
New golden bytes are pinned for tags 8-11 and for a trade settle.

Evidence: 35 tests across five files, clippy clean. The whole-system simulator now
also runs the clock, a periodic reconciler, a settler that stalls for long stretches
(about 1.8K blocked ticks per 10 runs), adjustments and fee withdrawals; at the end
nobody cancels anything and the reconciler alone must empty every ledger within five
sweep rounds, with no hold left, matching empty, money conserved including
adjustments, and fees paid out and returned. Mutation testing (18 mutations: clock
backwards, birth not recorded, sweep ignoring age, `max`, or its own marking, retry
always or never, maker and taker swapped, the taker flag ignored on one side, the
per-symbol schedule ignored, fee withdrawal not debiting the pool, an unpaid fee
withdrawal not returned, adjust not idempotent, overdraw, either direction not
counted in conservation, the fee account open to users, an unbounded ring) were all
caught, plus a sweep that releases holds itself, caught by the simulator's
live-order check and the property tests.

Not done here: an age index for the sweep; fee tiers by account or volume; wiring
`Clock` to leader timestamps (needs the command-format sidecar); the withdrawal
integration itself.

## 16. Step 5: credit slices (phase 2)

Design: `CREDIT-SLICES.md`. Built in `orderer-ledger` (`Slice`, the lent-funds side
of `Ledger`) and `orderer-exchange` (credit mode of `MatchingTierSm`, the group
stream). Every claim below was run; numbers are from this build.

**What exists.** `Lend` and `Recall` commands; `Grant` and `Recall` outbox messages
(through the same exactly-once intake as phase 1); four settle events from the
group, `SliceIn`, `SliceOut`, `SliceFee` and `Returned`, applied through the same
chained marks; `Slice`, the group's credit table (a small ledger of its own: local
pre-trade check, fills, fees, recall of uncommitted credit only, exact reports);
and in the matching tier a credit mode: gateway requests (entry tag 6) are checked
against the slice and entered in one replicated entry, fills are settled into the
slice at deterministic *credit epochs*, and the slice's reports go to an extra
stream (`source_base + partitions`) read like the partition streams.

**Differences from the proposal**, found while building:
- **One group per ledger shard pairing.** A ledger shard has one outbox, so it has
  one destination group; `lent_to[group]` is just `lent`. A shard talking to several
  groups needs per-group outboxes.
- **No recall id, no recall state.** `Recall` is a request; `Returned` is the answer
  (up to the uncommitted credit, possibly nothing). A withdrawal draws on `available`
  only, so it cannot pay out lent funds by construction (S4); a client that wants to
  withdraw more recalls first and retries.
- **Reports are net per account and asset**, not per fill: `SliceIn` (net of fee) or
  `SliceOut`, plus `SliceFee` for the fees the group charged, booked in the fee
  pool of shard 0 (a convention of the routing function, `settle_cmds_routed`).
  Before a `Returned` the group reports that account's net first, so the ledger's
  `lent` always covers a return.
- **Order ids come from the group**, with bit 15 of the shard field set, so ledger
  shard numbers are below 0x8000 and no ledger mistakes a slice order for its own. No
  id blocks are leased; the gateway learns the id from the reply.
- **Epochs cost a pipeline barrier.** Fills reach the group asynchronously (the
  partitions emit on their own threads), so they are applied at every `epoch`-th
  applied entry, after a barrier, reading each partition's new events in partition
  order. That keeps the slice a pure function of the log (three replicas and a
  restored one agree) but proceeds and released holds are spendable only after the
  next epoch, and the barrier is not free (see the measurement).

**Formats.** Commands 12 `Lend` and 13 `Recall`; settle event kinds 3 `SliceIn`,
4 `SliceOut`, 5 `SliceFee`, 6 `Returned`; outbox kinds 3 `Grant`, 4 `Recall`
(forwarded as the same 30-byte message, the amount split over the price and quantity
fields); tier entry tag 6 (request); snapshots `LDG3` (ledger) and `XTS2` (tier), each
written **only when phase 2 state or credit mode exists**, so a phase 1 ledger's
snapshot and digest are byte-identical to before. All other layouts are unchanged.

**Invariants.** Lent funds are the account's money: `holdings` includes them, and
each shard checks `lent + returned + slice_out == granted + slice_in` and the old
local identity. Across the system, at every step of the simulator, exactly:
`slice money - (slice in - slice out against phase 1 orders) == lent - applied in +
applied out - grants not yet accepted - returns not yet applied` (S1, in flight
included). S2 (no overdraft) is the slice's and ledgers' `check()`, S3 the intake
order and chained marks, S4 the withdrawal assertion in the simulator.

**Evidence.**
- 11 unit tests (lend, recall, slice events, anomalies, wire, snapshot format
  compatibility, the engine's check, exact reports, recall order, phase 1 ids ignored,
  snapshot restore) and 9 tier tests (wire, local credit check, epoch reports, recall,
  duplicate grants, mixed phase 1/2 trades, three replicas with 4 partitions plus a
  restored replica agreeing on digests and streams across epochs, snapshot mode
  mismatch, the group stream settled into a real ledger and everything recalled).
- Whole-system simulator `tests/slices.rs`: 1 and 3 shards, 30 seeds x 3,000 steps
  each, gateways entering orders at the group, grants, recalls, withdrawals, phase 1
  orders alongside, 8% loss, 7% duplication, reordering, crashes of forwarders,
  settlers and gateways, ledger and group failovers. Census over 20 seeds: 3.1K drops,
  2.8K duplicates, 1.3K role crashes, 243 ledger and 203 group failovers, 199 orders
  entered through slices, 660 refused by the local credit check, 197 trades involving
  slice orders (154 against phase 1 orders), 831 returns, 315 settles refused as gaps.
  After faults stop: converged, no anomaly, money conserved across shards, every lent
  unit recalled and returned.
- Mutation tests, 17 injected bugs, all caught by assertion (none by compile error):
  credit check skipped; reports re-sent (`p` not advanced); recall takes committed
  funds; withdrawal may use lent funds; grant applied again on a duplicate; recall
  without reporting net first; slice fees never reported; `Returned` not credited;
  `SliceOut` letting lent go negative; `Lend` not moving funds; slice settling foreign
  events (ledger and simulator); and in the tier: epoch without the barrier, request
  dedup removed, grants bypassing the intake, reports never appended to the group
  stream, epoch cursors not advanced, snapshot without the credit section. Caveat:
  "credit check skipped" mutates `Ledger::reserve`, which both phases use.

**Measurement** (`credit_bench`, release build, one thread, state-machine level: no
network, log, fsync or replication; 100,000 orders, 1,000 accounts, 4 symbols; ns per
order on the apply path):

| | 1 partition | 4 partitions |
|---|---|---|
| phase 1: ledger `Reserve` + forwarded `Submit`, one per entry | 1,264 | 1,168 |
| phase 1, forwarded in batches of 32 | 636 | 597 |
| phase 2, one request per entry, epoch 64 | 17,267 | 20,039 |
| phase 2, epoch 1,024 | 3,954 | 3,913 |
| phase 2, epoch 16,384 | 1,390 | ~1,700 |
| phase 2, no epoch | 1,113 | ~1,130 |

What it shows: per-order CPU of the credit path itself (about 1.1 us) is the same as
phase 1's two applies; the **epoch barrier costs about 1 ms**, so short epochs make the
apply path far slower than phase 1, and the epoch must be thousands of entries. What it
does not show: the point of phase 2, one replicated hop instead of two, is network
round trips and fsyncs that this test cannot see; order-to-ack latency on the
open-loop harness is not measured. Phase 1's settlement into the ledger is off the
order path and not counted; phase 2's own settlement (the epochs) is.

**Not done.** Refill policy and automatic lending (Lend and Recall are explicit);
per-group outboxes (several groups per ledger shard); a driver for idle groups (an
epoch is entry-counted, so a quiet group needs periodic no-op entries from its node);
a network service for tag 6 requests and the group stream's use by the real-process
scripts (the tier exposes them in process and through `TierView::read`); IOC and
market orders at the group (orders entered are GTC limits); an age sweep for slice
orders (the phase 1 reconciler does not see them); a cheaper epoch (a barrier-free
scheme would need the matcher's fills to be applied on the log's own thread);
real-process `kill -9` runs with slices; position or rate limits in the credit table.
