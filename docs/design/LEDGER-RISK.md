# Proposal: ledger and pre-trade risk

Status: **proposal, for review. Nothing here is implemented.** Read
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
  otherwise it is applied and `hw` advances. Events for one shard arrive in stream
  order, possibly with gaps (other shards' events), which is enough for a
  monotonic mark. That is the whole exactly-once argument.

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
