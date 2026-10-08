//! W6 — multi-symbol engine corpus for the pipeline scaling gate
//! (spec/BENCH.md §1). This source is normative: its draw order defines the
//! corpus. Never change output for an existing seed.
//!
//! One xorshift64* stream (seeded `seed | 1`, as vectorgen). Each symbol
//! keeps its own vectorgen-style state (next order id from 1, live ids). Every
//! step draws the symbol first, then performs exactly vectorgen's W1 add
//! (setup) or W4 step (run) on that symbol, with the same draw order.

use std::io::Write as _;

use crate::types::{Command, OType, Side, Tif};

const MID: i64 = 500_000;
const PMIN: i64 = MID - 10_000;
const PMAX: i64 = MID + 10_000;

/// xorshift64* — identical to vectorgen's.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
    fn range(&mut self, lo: i64, hi: i64) -> i64 {
        lo + self.below((hi - lo) as u64) as i64
    }
}

#[derive(Default)]
struct Sym {
    next_id: u64,
    live: Vec<u64>,
    news: usize,
}

struct W6 {
    rng: Rng,
    syms: Vec<Sym>,
    line: String,
}

impl W6 {
    fn emit(&mut self, sym: usize, cmd: Command, out: &mut String) {
        if matches!(cmd, Command::New { .. }) {
            self.syms[sym].news += 1;
        }
        self.line.clear();
        cmd.write_canonical(&mut self.line);
        // engine form: "symbol" right after "cmd" (spec/matcher/SCHEMA.md)
        let at = self.line.find(',').unwrap();
        out.push_str(&self.line[..at]);
        out.push_str(&format!(",\"symbol\":{sym}"));
        out.push_str(&self.line[at..]);
        out.push('\n');
    }

    fn rand_side(&mut self) -> Side {
        if self.rng.below(2) == 0 {
            Side::Bid
        } else {
            Side::Ask
        }
    }

    /// vectorgen `add_cmd(side, 1, 5_000, 100)`.
    fn add(&mut self, sym: usize, out: &mut String) {
        let side = self.rand_side();
        let (lo, hi) = match side {
            Side::Bid => (MID - 5_000, MID - 1),
            Side::Ask => (MID + 1, MID + 5_000),
        };
        let st = &mut self.syms[sym];
        st.next_id += 1;
        let id = st.next_id;
        let price = self.rng.range(lo, hi);
        let qty = self.rng.below(100) + 1;
        self.syms[sym].live.push(id);
        self.emit(sym, Command::new(id, side, price, qty, Tif::Gtc), out);
    }

    /// vectorgen's W4 step, on `sym`.
    fn w4(&mut self, sym: usize, out: &mut String) {
        let r = self.rng.below(100);
        let has_live = !self.syms[sym].live.is_empty();
        if r < 82 && has_live {
            let i = self.rng.below(self.syms[sym].live.len() as u64) as usize;
            let id = self.syms[sym].live[i];
            let side = if self.rng.below(2) == 0 { Side::Bid } else { Side::Ask };
            let (price, qty) = match side {
                Side::Bid => (self.rng.range(MID - 5_000, MID - 1), self.rng.below(100) + 1),
                Side::Ask => (self.rng.range(MID + 1, MID + 5_000), self.rng.below(100) + 1),
            };
            self.emit(sym, Command::replace(id, price, qty), out);
        } else if r < 88 && has_live {
            let i = self.rng.below(self.syms[sym].live.len() as u64) as usize;
            let id = self.syms[sym].live.swap_remove(i);
            self.emit(sym, Command::cancel(id), out);
        } else if r < 91 {
            self.syms[sym].next_id += 1;
            let id = self.syms[sym].next_id;
            let side = self.rand_side();
            let qty = self.rng.below(50) + 1;
            let price = match side {
                Side::Bid => MID + self.rng.range(1, 100),
                Side::Ask => MID - self.rng.range(1, 100),
            };
            self.emit(
                sym,
                Command::New {
                    order_id: id,
                    side,
                    otype: OType::Limit,
                    price,
                    qty,
                    tif: Tif::Ioc,
                },
                out,
            );
        } else {
            self.add(sym, out);
        }
    }
}

pub fn run(out_prefix: &str, seed: u64, n: usize, setup_n: usize, symbols: usize) {
    assert!(symbols >= 1, "--symbols must be ≥ 1");
    let mut g = W6 {
        rng: Rng(seed | 1),
        syms: (0..symbols).map(|_| Sym::default()).collect(),
        line: String::with_capacity(160),
    };
    let mut setup = String::with_capacity(setup_n * 96);
    let mut run = String::with_capacity(n * 96);
    for _ in 0..setup_n {
        let s = g.rng.below(symbols as u64) as usize;
        g.add(s, &mut setup);
    }
    for _ in 0..n {
        let s = g.rng.below(symbols as u64) as usize;
        g.w4(s, &mut run);
    }
    let max_orders = g.syms.iter().map(|s| s.news).max().unwrap_or(0) + 16;
    let header = format!(
        "{{\"format\":\"matcher-vector/1\",\"name\":\"w6\",\"engine\":true,\"pmin\":{PMIN},\"pmax\":{PMAX},\"max_orders\":{max_orders},\"index\":\"ladder\",\"workload\":\"w6\",\"seed\":{seed},\"symbols\":{symbols}}}\n"
    );
    for (suffix, body) in [("setup", &setup), ("run", &run)] {
        let mut f = std::fs::File::create(format!("{out_prefix}.{suffix}.cmd.jsonl")).unwrap();
        f.write_all(header.as_bytes()).unwrap();
        f.write_all(body.as_bytes()).unwrap();
    }
    eprintln!(
        "ordergen w6: symbols={symbols} setup={setup_n} run={n} seed={seed} max_orders={max_orders} -> {out_prefix}.{{setup,run}}.cmd.jsonl"
    );
}
