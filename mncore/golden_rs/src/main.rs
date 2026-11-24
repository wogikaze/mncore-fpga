//! Runs a VSM program on the viz/core simulator and prints what its `d get` lines read, as the
//! body of an ndmp file (contract 06 section 4): one line per long word, sorted, without header.
//!
//! Usage: golden_dump <program.vsm | ->
//!
//! The input is the whole program as the official emulator sees it: a testcase prefix (`d set`,
//! `r` lines), the solution, the testcase suffix and any extra `d get` probe lines. Lines other
//! than `d get` are executed with `mncore_sim::run::Sim`. `d get` is handled here instead of by
//! `Sim::debug_get` so that every access form of SDM 3.4.3 is supported and the records come out
//! already named and numbered like the official dump after `norm_gpfn3.py`:
//!
//! - `LM0 LM1 GRF0 GRF1`: long word address (word address >> 1), for `$l*` and `$ll*` access.
//! - `LM0W LM1W GRF0W GRF1W`: word address, for word access (`d getf $m0 ...`).
//! - `T`: 2 * cycle + k, where k = 0 is the MSB long word of the cycle and k = 1 the LSB one.
//! - `OMR`: entry * 4 + cycle, value is the 4-bit flag nibble.
//! - `L1BM L2BM PDM DRAM`: long word address. `$llb<a>` reads long words a and a + 4.
//!
//! When a location is read more than once, the last read wins. Addresses have 4 hex digits
//! (8 for PDM and DRAM), as in `mncore/tools/golden/ndmp.py`; `run_rust.py` adds the header.
//! The number of instruction words (`j` + `m`) goes to stderr as `words=<n>`.
//!
//! Exit codes: 0 success, 2 the simulator does not support a line, 3 parse error, 4 I/O error.

use std::collections::HashMap;
use std::io::{BufWriter, Read, Write};

use mncore_sim::blocks::{L1BS, L2BS};
use mncore_sim::machine::{MemRead, PeId, PES};
use mncore_sim::mv::GROUPS;
use mncore_sim::run::Sim;
use mncore_sim::vsm::{self, DebugLoc, Line, MemKind};

type Rec = (&'static str, String, u64, u64);

fn pes_of(loc: &DebugLoc) -> Vec<usize> {
    (0..PES)
        .filter(|&i| {
            let id = PeId::from_index(i);
            loc.group.is_none_or(|g| g == id.group)
                && loc.l2b.is_none_or(|g| g == id.l2b)
                && loc.l1b.is_none_or(|g| g == id.l1b)
                && loc.mab.is_none_or(|g| g == id.mab)
                && loc.pe.is_none_or(|g| g == id.pe)
        })
        .collect()
}

/// L1B (or L2B) indices selected by a location, with their path names.
fn blocks_of(loc: &DebugLoc, l1: bool) -> Vec<(usize, String)> {
    let n = if l1 { L1BS } else { L2BS };
    (0..n)
        .filter_map(|i| {
            let (g, c, b) = if l1 { (i / 16, i / 8 % 2, i % 8) } else { (i / 2, i % 2, 0) };
            let ok = loc.group.is_none_or(|x| x as usize == g)
                && loc.l2b.is_none_or(|x| x as usize == c)
                && (!l1 || loc.l1b.is_none_or(|x| x as usize == b));
            ok.then(|| (i, if l1 { format!("n{g}c{c}b{b}") } else { format!("n{g}c{c}") }))
        })
        .collect()
}

/// Reads what one `d get` prints, in the official emulator's semantics.
fn debug_get(sim: &Sim, loc: &DebugLoc, count: u32, dtype: Option<char>, out: &mut Vec<Rec>) -> Result<(), String> {
    let count = count as u64;
    let base = loc.addr as u64;
    match loc.mem {
        MemKind::Dram | MemKind::Pdm => {
            // The official emulator labels `$p` as PIU; ndmp calls it PDM.
            let dram = loc.mem == MemKind::Dram;
            for g in (0..GROUPS).filter(|&g| loc.group.is_none_or(|x| x as usize == g)) {
                for i in 0..count {
                    let a = base + i;
                    let v = if dram { sim.off.dram[g].get(a) } else { sim.off.pdm[g].get(a) };
                    out.push((if dram { "DRAM" } else { "PDM" }, format!("n{g}"), a, v));
                }
            }
        }
        MemKind::L1bm | MemKind::L2bm => {
            let l1 = loc.mem == MemKind::L1bm;
            for (b, path) in blocks_of(loc, l1) {
                let mem = if l1 { &sim.m.blocks.l1bm[b] } else { &sim.m.blocks.l2bm[b] };
                let len = mem.len() as u64;
                let name = if l1 { "L1BM" } else { "L2BM" };
                for i in 0..count {
                    let a = base + i;
                    out.push((name, path.clone(), a, mem[(a % len) as usize]));
                    if l1 && loc.wl == 4 {
                        // Two long word access of L1BM pairs long word a with a + 4.
                        out.push((name, path.clone(), a + 4, mem[((a + 4) % len) as usize]));
                    }
                }
            }
        }
        MemKind::Omr => {
            for pe in pes_of(loc) {
                let p = &sim.m.pes[pe];
                let pname = PeId::from_index(pe).name();
                for i in 0..count {
                    let entry = base + i;
                    for c in 0..4u64 {
                        let v = match entry {
                            0 => 0xf,
                            1..=15 => ((p.mask[entry as usize] >> (4 * c)) & 0xf) as u64,
                            _ => {
                                if (entry >> (3 - c)) & 1 == 1 {
                                    0xf
                                } else {
                                    0
                                }
                            }
                        };
                        out.push(("OMR", pname.clone(), entry * 4 + c, v));
                    }
                }
            }
        }
        MemKind::T => {
            // `$t` and `$lt` read the MSB long word of cycle i; `$llt` reads both long words.
            let per = if loc.wl == 4 { 2 } else { 1 };
            for pe in pes_of(loc) {
                let p = &sim.m.pes[pe];
                let pname = PeId::from_index(pe).name();
                for i in 0..count as usize {
                    let c = i % 4;
                    for k in 0..per {
                        let w = c * 4 + 2 * k;
                        let v = ((p.t[w] as u64) << 32) | p.t[w + 1] as u64;
                        out.push(("T", pname.clone(), (2 * c + k) as u64, v));
                    }
                }
            }
        }
        MemKind::Lm0 | MemKind::Lm1 | MemKind::Grf0 | MemKind::Grf1 => {
            let (name, wname) = match loc.mem {
                MemKind::Lm0 => ("LM0", "LM0W"),
                MemKind::Lm1 => ("LM1", "LM1W"),
                MemKind::Grf0 => ("GRF0", "GRF0W"),
                _ => ("GRF1", "GRF1W"),
            };
            if loc.wl == 1 && !matches!(dtype, Some('f') | Some('h')) {
                // The emulator stops with "Target type is smaller than expected format".
                return Err("d get with word access needs dtype f or h".into());
            }
            let long = |pe: usize, lw: u64| -> u64 {
                let a = (2 * lw) as usize;
                ((sim.m.mem.peek(loc.mem, pe, a) as u64) << 32) | sim.m.mem.peek(loc.mem, pe, a + 1) as u64
            };
            for pe in pes_of(loc) {
                let pname = PeId::from_index(pe).name();
                for i in 0..count {
                    match loc.wl {
                        1 => {
                            let a = base + i;
                            let v = sim.m.mem.peek(loc.mem, pe, a as usize) as u64;
                            out.push((wname, pname.clone(), a, v));
                        }
                        2 => {
                            // A long word access at an odd word address reads the aligned long word.
                            let lw = (base + 2 * i) >> 1;
                            out.push((name, pname.clone(), lw, long(pe, lw)));
                        }
                        _ => {
                            let lw = (base + 4 * i) >> 1;
                            out.push((name, pname.clone(), lw, long(pe, lw)));
                            out.push((name, pname.clone(), lw + 1, long(pe, lw + 1)));
                        }
                    }
                }
            }
        }
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let Some(path) = args.get(1) else {
        eprintln!("usage: golden_dump <program.vsm | ->");
        std::process::exit(4);
    };
    let mut src = String::new();
    let read = if path == "-" {
        std::io::stdin().read_to_string(&mut src).map(|_| ())
    } else {
        std::fs::read_to_string(path).map(|s| src = s)
    };
    if let Err(e) = read {
        eprintln!("ERROR cannot read {path}: {e}");
        std::process::exit(4);
    }

    let lines = match vsm::parse(&src) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("PARSE {e}");
            std::process::exit(3);
        }
    };

    let mut sim = Sim::new();
    let mut recs: Vec<Rec> = Vec::new();
    for (lineno, line) in &lines {
        let res = match line {
            Line::DebugGet { loc, count, dtype, .. } => debug_get(&sim, loc, *count, *dtype, &mut recs),
            other => sim.exec(other).map_err(|e| e.message()),
        };
        if let Err(msg) = res {
            let text = src.lines().nth(lineno - 1).unwrap_or("");
            let text: String = text.chars().take(200).collect();
            eprintln!("UNSUPPORTED line {lineno}: {msg}\n  {text}");
            std::process::exit(2);
        }
    }

    // Canonical ndmp body: the last read of a location wins, lines sorted as byte strings
    // (the same order as Python's sorted() on ndmp.format_line()).
    let mut last: HashMap<(&'static str, String, u64), u64> = HashMap::with_capacity(recs.len());
    for (space, loc, addr, val) in recs {
        last.insert((space, loc, addr), val);
    }
    let mut out: Vec<String> = last
        .into_iter()
        .map(|((space, loc, addr), val)| {
            if matches!(space, "PDM" | "DRAM") {
                format!("{space} {loc} 0x{addr:08x} {val:016x}")
            } else {
                format!("{space} {loc} 0x{addr:04x} {val:016x}")
            }
        })
        .collect();
    out.sort_unstable();
    let stdout = std::io::stdout();
    let mut w = BufWriter::new(stdout.lock());
    for line in &out {
        if writeln!(w, "{line}").is_err() {
            std::process::exit(4);
        }
    }
    if w.flush().is_err() {
        std::process::exit(4);
    }
    eprintln!("words={}", sim.words);
}
