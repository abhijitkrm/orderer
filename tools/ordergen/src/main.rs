//! ordergen — deterministic corpus + fuzz generator for orderer
//! (spec/BENCH.md §1). A strict superset of matcher's two tools:
//!
//!   ordergen --workload w1..w5 --out P [--seed S --n N --setup-n M]
//!       corpus mode — byte-identical to matcher's `vectorgen`
//!   ordergen --workload w6 --out P [--symbols K --seed S --n N --setup-n M]
//!       multi-symbol engine corpus for the pipeline scaling gate
//!   ordergen [--seed S --n N --symbols K --ids I --pmin A --pmax B] > f
//!       fuzz mode — byte-identical to matcher's `fuzzgen`
//!   ordergen --exhaustive D --out DIR
//!       every length-D sequence over fuzzgen's alphabet
//!
//! Same arguments ⇒ byte-identical output, forever.

mod corpus;
mod fuzz;
#[allow(dead_code)]
mod types;
mod w6;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--workload") {
        corpus::run(args);
    } else {
        fuzz::run(args);
    }
}
