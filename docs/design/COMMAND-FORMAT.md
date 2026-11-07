# Proposal: command format v2 (accounts, sequencer time, ids)

Status: **proposal, for review. Nothing here is implemented.** Decisions that
need an answer are collected in the last section.

## 1. Why now

Everything above the matcher (balances, risk, market data, audit, fees) needs
three things the log does not carry today:

1. **Who owns an order.** A command is `(symbol, order_id, side, price, qty,
   tif)`. There is no account, so no balance check, no ownership check on cancel,
   no per-account mass cancel, no execution report routing.
2. **Time that every replica agrees on.** Audit, expiry (day / good-till-date
   orders) and market-data timestamps need a timestamp that is part of the
   replicated log. A replica must never read its own clock while applying.
3. **Identifiers that are unique across accounts.** Today `order_id` is unique
   per book and chosen by the client, so two accounts can collide, and a
   collision is both a rejected legitimate order and an information leak.

Every layer built on top inherits this decision, and the format change gets
costlier with each added consumer and each added language. Hence a proposal
before any further layer is built.

## 2. Principle: do not touch the matcher

The matcher `Command`, the journal record, the golden vectors, the pipeline
and the event-chain digest (REPLICATION 13.16) stay exactly as they are. That is
what keeps this change small: five matcher repos, five journal codecs and every
vector are untouched. The new information lives in the **replicated log entry**
and in layers *around* the matcher, and the matching pipeline simply ignores the
bytes it does not need. The one feature that needs the matcher to know an owner,
self-trade prevention, is separated out (section 7).

## 3. Decisions

**D1. Account lives in a per-command sidecar, not in the matcher command.**
A new entry type carries, next to each 32-byte matcher command, an `account u64`.
`PipelineSm.apply` reads the 32 bytes as before and skips the account.
Alternatives rejected: adding the account to the matcher `Command` (touches every
matcher, journal, vector and the digest, for a field the matching algorithm does
not use); one account per batch (a gateway batches by arrival, not by account).

**D2. Timestamp is stamped by the leader, once per entry, and is part of the log.**
The leader's replica writes `ts_ns` into the entry header when it proposes, so the
value is replicated like any other byte and every replica reads the same one.
`ts = max(leader clock in ns since the Unix epoch, previous entry's ts + 1)`. A
new leader seeds "previous" from the last entry in its log, so time never goes
backwards across failovers even if clocks are skewed (it may stall briefly, never
regress). Clients cannot choose it. The pipeline is given the entry's `ts` as the
commands' publish time, so events carry a deterministic timestamp to the egress
(a small pipeline API addition: publish with an explicit time).

**D3. Order ids are assigned by the ledger shard that holds the account, and carry
that shard in their high bits.**
`order_id = ledger_shard (16 bits) << 48 | per-shard counter (48 bits)`. That makes
ids unique by construction, makes a trade routable to the two ledger shards that
must settle it *from the ids alone*, with no lookup (see LEDGER-RISK.md), and
removes client-chosen ids from the log. The gateway keeps the mapping from the
client's own order reference to the engine id. Until the ledger exists, a gateway
may assign ids from its own range with the same layout.

**D4. Trade ids are not a new field.** A trade is identified by
`(matching group, symbol, event seq)`; the per-book event sequence is already unique
and replicated. No format change.

**D5. Administrative commands are sequenced entries of their own.** Halting and
resuming a symbol, price bands, cancel-all, instrument creation and so on take
effect at a deterministic point in the log, so they are entries of a second type
rather than out-of-band calls. What a halt *does* inside the matcher is matcher-spec
work and is out of scope here; the entry type is reserved now so the log format
does not change again.

**D6. Idempotence stays where it is.** Sessions (`client`, `seq`) already give
exactly-once at the batch level and keep working unchanged.

## 4. Wire format

Entry payload tags today: `1` plain batch, `2` session batch. Both stay valid.
New tags:

```
tag 3  sequenced batch
  0     u8   3
  1     u8   version (1)
  2     u16  flags (0; reserved)
  4     u64  session client id (0 = none)
  12    u64  session seq
  20    u64  ts_ns            written by the leader; zero when proposed
  28    u32  n
  32    n x { cmd32 (as today) | account u64 }          40 bytes each

tag 4  control entry
  0     u8   4
  1     u8   version (1)
  2     u16  kind (1 halt, 2 resume, 3 set bands, 4 cancel-all(account), ...)
  4     u64  session client id
  12    u64  session seq
  20    u64  ts_ns            written by the leader
  28    u32  len
  32    len bytes, by kind
```

`SessionOf` reads tag 3 and 4 like tag 2 (same offsets). `account == 0` means
"unattributed" and is allowed only on a cluster configured for it; a risk layer
rejects it. The leader recognises tag 3 and 4 only to stamp `ts_ns`; the consensus
core still sees opaque bytes, so **no protocol, WAL, snapshot or wire change**.

## 5. What changes where

| Layer | Change | Languages |
|---|---|---|
| matcher cores, journals, vectors | none | none |
| pipeline, digest | one API addition: publish a batch with an explicit time | five (small) |
| log entry codec | parse and write tags 3 and 4; vectors for them | five (small) |
| replica | leader stamps `ts_ns`; a new leader seeds it from its log | Rust first, then ports |
| `PipelineSm` | accept tag 3 (skip accounts, pass `ts`) | five (small) |
| new: ledger, gateway, settler | built on the above | Rust only (reference) |

The vectors are new files (`vectors/replication-wire/` gains entries for tags 3
and 4); no existing vector changes. Mixed-version clusters are not supported
across this change, but a log that only contains tags 1 and 2 stays valid.

## 6. Verification

- Wire fixtures for tags 3 and 4 written by Rust and read by every port, in the
  same style as the existing batch fixtures (decode, re-encode, truncation at every
  prefix, hostile input).
- A test that the leader's `ts` is strictly increasing across entries and across
  a leader change with a skewed clock (simulated by an injectable clock).
- A test that a replica applying the log never reads its own clock (an injectable
  clock that panics on the apply path).
- Every existing vector, digest and mixed-language run must pass unchanged, which
  is the proof that the matcher was not touched.

## 7. Deliberately deferred

**Self-trade prevention** has to be decided *inside matching* (it compares the
owner of the incoming order with the owner of each resting order), so it cannot
live in a sidecar. It needs an optional `owner u32` on resting orders in the
matcher, a rule for what happens on a would-be self-trade (cancel newest, cancel
oldest, cancel both, decrement), and its own golden vectors, in all five matcher
repos. It is independent of this proposal and should be a matcher-spec change of
its own, driven by whether the venue wants it.

Also deferred: stop and iceberg orders, auctions, and tick or lot validation. All
are matcher features, none changes this log format.

## 8. Decisions needed from you

1. **Sidecar versus matcher field (D1).** I recommend the sidecar. The cost is that
   self-trade prevention needs its own later matcher change. Do you want STP in
   the first release? If yes, that changes the plan.
2. **Time source (D2).** Leader wall clock, monotonic-fixed across failovers, as
   above. The alternative is a dedicated sequencer clock (PTP-disciplined) with the
   same rule. Which clock quality do you need for audit?
3. **Order ids from the ledger (D3).** This ties the id layout to the ledger design.
   Fine if you accept the ledger proposal; otherwise gateway-assigned ids work too.
4. **Does a mixed-version cluster need to work across this change?** I assumed no:
   the system is pre-release, and a rolling upgrade across a format change is a
   separate piece of work.
