# Design: delegated credit slices (one-hop order path)

Status: design for roadmap step 5. Builds on `LEDGER-RISK.md` (phases 1, sections
1-14). Nothing here is implemented until section 9 says so.

## 1. Problem

Phase 1 puts two serial replicated hops before an order rests in a book: the
ledger commits `Reserve`, then matching commits the forwarded `Submit`. At tens of
microseconds per hop that is the floor for order-to-ack latency. Phase 2 removes the
ledger hop from the common path without weakening I1-I5.

## 2. Idea

The ledger **lends** a matching group a *slice* of an account's balance: a standing
reservation for `(account, asset)` held by the ledger as `lent` and recorded in the
matching group as `credit`. The matching group's state machine then does the
pre-trade check against its local credit (an array lookup, no network) and the order
enters the book in a single replicated hop. Trades between accounts that both have
slices in the group settle locally, atomically with matching. The ledger learns net
movements afterwards, in order, through the same chained-mark stream as phase 1.

A slice is not a new kind of money. It is a hold with a different owner, so
conservation is: `available + held + lent` per account, summed with credit state
held by matching groups, never changes except by deposits, withdrawals, fees.

## 3. State

Ledger, per `(account, asset)`: `available`, `held` (phase 1 order holds), `lent`
(sum over groups). Per `(account, asset, group)`: `lent_to[group]`.

Matching group, per `(account, asset)`: `credit` (what it may still commit) and
`committed` (what open orders here already hold against it); `credit` never
goes negative.

## 4. Messages (all exactly-once, chained like phase 1)

Ledger -> group (outbox, contiguous index, intake accepts only the next index):
- `Grant { account, asset, amount }`: `credit += amount`.
- `Recall { account, asset, amount, recall_id }`: ask the group to give back up to
  `amount` of *uncommitted* credit.

Group -> ledger (the group's event stream, which already feeds the settler; the
chained `Settle` mark makes it exactly once):
- `Net { account, asset, delta_in, delta_out }`: movements since the last report
  (fills settled locally; fees). Applied to `lent`/`available` per section 5.
- `Returned { account, asset, amount, recall_id }`: the group removed `amount` of
  uncommitted credit (possibly less than asked) and stopped using it.

## 5. Ledger rules

- `Lend(account, asset, group, amount)`: `available -= amount; lent += amount;
  lent_to[group] += amount`; queue `Grant`. Triggered by the gateway on first order
  for that account in that group, by a refill policy, or explicitly. Rejected if
  `available` is short.
- `Net`: the group says the account paid `out` and received `in` of an asset
  *within* its slice. `lent_to[group] -= out; lent_to[group] += in` and the same on
  `lent`: money that arrives in a slice (sale proceeds) stays in that slice until
  returned. Underflow is an anomaly (never happens in correct operation).
- `Returned`: `lent -= amount; lent_to[group] -= amount; available += amount`.
- `WithdrawRequest` first issues `Recall` for the shortfall and completes only after
  the matching `Returned`s arrive (state `Recalling`); until then it holds nothing
  and may be refused or time out.
- Fees: charged by the group at fill time against the slice, reported in `Net`, and
  credited to the fee account on the ledger when applied. Conservation holds because
  `Net` carries them explicitly.

## 6. Matching-group rules

- New order: reject unless `credit >= required` (buy: price*qty quote; sell: qty*lot
  base); else `credit -= required; committed += required` and the order enters the
  book, in one replicated hop. The order id is still assigned by the ledger shard
  (a block of ids is leased with the first `Grant` so the gateway needs no round trip).
- Fill: both sides in this group, settled locally: the buyer's quote `committed`
  falls by the limit hold, price improvement and base proceeds go to `credit` (base
  asset slice, created on demand with zero), seller likewise. Proceeds are credit
  immediately usable for new orders. All of this is part of the same deterministic
  `apply`, so it is atomic with the match.
- `Recall`: `give = min(amount, credit)`; `credit -= give`; emit `Returned`.
  Committed funds are never recalled; the gateway cancels orders first when it needs
  funds back.
- Cancel/close: `committed -> credit`.

## 7. Invariants

- **S1 conservation** (per asset, whole system): `sum(available + held) over
  ledger accounts + fees + sum(lent) = deposits - withdrawals`, and for every
  `(account, asset, group)`: `lent_to[group] = credit + committed` (group) +
  in-flight `Grant`s - in-flight `Returned`s - unreported `Net`s. The last terms make
  the equality exact only at quiescence; the simulator checks the safety half
  continuously: group `credit + committed` never exceeds what the ledger has lent plus
  what has been reported in.
- **S2 no overdraft**: `credit` and every ledger balance stay non-negative; a group
  cannot commit more than it was lent (the group's check is local and total).
- **S3 exactly once**: `Grant` by intake cursor, `Net`/`Returned` by chained marks.
- **S4 withdrawals** never pay out funds that are lent or committed.

## 8. Costs and limits

- An account trading in many groups needs a slice per group: more lent funds, more
  recalls. Policy defaults: lend on first use, refill below a low-water mark, cap per
  group, return idle slices after a timeout.
- A recalled-and-withdrawn account may see orders rejected for lack of credit even
  though the ledger shows `available`: that is correct (funds are being recalled).
- Latency: order path is one replicated hop (gateway to group); a refill is a
  ledger hop but off the critical path when the water mark is right.
- Failure: a group failing over keeps `credit` (replicated state). A ledger failing
  over keeps `lent`. The reconcilers of phase 1 apply unchanged (a lost `Net` shows
  as an anomaly in the audit, not as lost money, because `Net` is chained).

## 9. Verification and roadmap

1. Ledger side: `Lend`, `Net`, `Returned`, recall state; unit and property tests.
2. Group side: credit table in the matching tier SM, local settle; unit tests.
3. Simulator: extend the whole-system sim with slices, refills and recalls under the
   same faults; check S1-S4 each step; mutations (skip credit check, double-apply Net,
   recall committed funds, withdraw lent funds).
4. Real processes: `kill -9` of ledger and group leaders with the audit running.
5. Measure: order-to-ack latency on the open-loop harness, phase 1 vs phase 2.

## 10. Open questions

- Slice sizing policy (static vs adaptive per account activity).
- Whether market data / risk checks beyond balance (position limits, rate limits)
  also live in the group's credit table. Leaning yes, same mechanism.
- A shared multi-asset credit (portfolio margin) is out of scope.
