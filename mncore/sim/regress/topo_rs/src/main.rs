//! Runs a VSM program on the viz/core simulator on a reduced topology and prints what its `d get`
//! lines read, as the body of an ndmp file (contract 06 section 4): one line per long word, sorted,
//! without header (WP37: the zero-rule reference of the M2 regression, contract 06 section 3 (a)).
//!
//! Usage: topo_dump [--topology <spec>] <program.vsm | ->
//!
//! This is `mncore/golden_rs` (WP02's golden_dump) on `Sim::with_topology` (WP06): the same `d get`
//! forms and ndmp names (LM0 LM1 GRF0 GRF1 long words, LM0W .. word access, T 2 * cycle + k, OMR
//! entry * 4 + cycle, L1BM L2BM PDM DRAM long words, `$llb<a>` = a and a + 4), but only for the
//! units of the topology (PEs, L1Bs, L2Bs and the groups that have an L2B), with their chip
//! coordinates. A `d get` beyond a reduced capacity prints nothing for those addresses.
//!
//! Exit codes: 0 success, 2 the simulator does not support a line, 3 parse error, 4 I/O error,
//! 5 E_RANGE (an access beyond a reduced capacity; stderr: `RANGE word=<n> line=<l>: <message>`,
//! the records read before it are printed).

use std::collections::HashMap;
use std::io::{BufWriter, Read, Write};

use mncore_sim::machine::MemRead;
use mncore_sim::mv::GROUPS;
use mncore_sim::run::Sim;
use mncore_sim::topology::Topology;
use mncore_sim::vsm::{self, DebugLoc, Line, MemKind};

type Rec = (&'static str, String, u64, u64);

fn pes_of(topo: &Topology, loc: &DebugLoc) -> Vec<usize> {
    (0..topo.pes())
        .filter(|&i| {
            let id = topo.pe_id(i);
            loc.group.is_none_or(|g| g == id.group)
                && loc.l2b.is_none_or(|g| g == id.l2b)
                && loc.l1b.is_none_or(|g| g == id.l1b)
                && loc.mab.is_none_or(|g| g == id.mab)
                && loc.pe.is_none_or(|g| g == id.pe)
        })
        .collect()
}

/// Dense L1B (or L2B) indices of the topology selected by a location, with their path names.
fn blocks_of(topo: &Topology, loc: &DebugLoc, l1: bool) -> Vec<(usize, String)> {
    let n = if l1 { topo.l1bs() } else { topo.l2b };
    (0..n)
        .filter_map(|i| {
            let (g, c, b) = if l1 { topo.l1b_coords(i) } else { (i / 2, i % 2, 0) };
            let ok = loc.group.is_none_or(|x| x as usize == g)
                && loc.l2b.is_none_or(|x| x as usize == c)
                && (!l1 || loc.l1b.is_none_or(|x| x as usize == b));
            ok.then(|| (i, if l1 { topo.l1b_name(i) } else { Topology::l2b_name(i) }))
        })
        .collect()
}

/// Reads what one `d get` prints, in the official emulator's semantics, inside the topology.
fn debug_get(sim: &Sim, loc: &DebugLoc, count: u32, dtype: Option<char>, out: &mut Vec<Rec>) -> Result<(), String> {
    let topo = *sim.topology();
    let count = count as u64;
    let base = loc.addr as u64;
    match loc.mem {
        MemKind::Dram | MemKind::Pdm => {
            let dram = loc.mem == MemKind::Dram;
            let cap = if dram { topo.dram } else { topo.pdm };
            for g in (0..GROUPS).filter(|&g| !topo.group_absent(g) && loc.group.is_none_or(|x| x as usize == g)) {
                for i in 0..count {
                    let a = base + i;
                    if a >= cap {
                        continue;
                    }
                    let v = if dram { sim.off.dram[g].get(a) } else { sim.off.pdm[g].get(a) };
                    out.push((if dram { "DRAM" } else { "PDM" }, format!("n{g}"), a, v));
                }
            }
        }
        MemKind::L1bm | MemKind::L2bm => {
            let l1 = loc.mem == MemKind::L1bm;
            let cap = (if l1 { topo.l1bm } else { topo.l2bm }) as u64;
            for (b, path) in blocks_of(&topo, loc, l1) {
                let mem = if l1 { &sim.m.blocks.l1bm[b] } else { &sim.m.blocks.l2bm[b] };
                let name = if l1 { "L1BM" } else { "L2BM" };
                let mut push = |a: u64| {
                    if a < cap {
                        out.push((name, path.clone(), a, mem[a as usize]));
                    }
                };
                for i in 0..count {
                    let a = base + i;
                    push(a);
                    if l1 && loc.wl == 4 {
                        // Two long word access of L1BM pairs long word a with a + 4.
                        push(a + 4);
                    }
                }
            }
        }
        MemKind::Omr => {
            for pe in pes_of(&topo, loc) {
                let p = &sim.m.pes[pe];
                let pname = topo.pe_id(pe).name();
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
            let per = if loc.wl == 4 { 2 } else { 1 };
            for pe in pes_of(&topo, loc) {
                let p = &sim.m.pes[pe];
                let pname = topo.pe_id(pe).name();
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
            let (name, wname, words) = match loc.mem {
                MemKind::Lm0 => ("LM0", "LM0W", topo.lm_words()),
                MemKind::Lm1 => ("LM1", "LM1W", topo.lm_words()),
                MemKind::Grf0 => ("GRF0", "GRF0W", topo.grf_words()),
                _ => ("GRF1", "GRF1W", topo.grf_words()),
            };
            let words = words as u64;
            if loc.wl == 1 && !matches!(dtype, Some('f') | Some('h')) {
                return Err("d get with word access needs dtype f or h".into());
            }
            let long = |pe: usize, lw: u64| -> u64 {
                let a = (2 * lw) as usize;
                ((sim.m.mem.peek(loc.mem, pe, a) as u64) << 32) | sim.m.mem.peek(loc.mem, pe, a + 1) as u64
            };
            for pe in pes_of(&topo, loc) {
                let pname = topo.pe_id(pe).name();
                for i in 0..count {
                    match loc.wl {
                        1 => {
                            let a = base + i;
                            if a < words {
                                let v = sim.m.mem.peek(loc.mem, pe, a as usize) as u64;
                                out.push((wname, pname.clone(), a, v));
                            }
                        }
                        2 => {
                            let lw = (base + 2 * i) >> 1;
                            if 2 * lw < words {
                                out.push((name, pname.clone(), lw, long(pe, lw)));
                            }
                        }
                        _ => {
                            let lw = (base + 4 * i) >> 1;
                            for k in 0..2 {
                                if 2 * (lw + k) < words {
                                    out.push((name, pname.clone(), lw + k, long(pe, lw + k)));
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    Ok(())
}

fn print_records(recs: Vec<Rec>) {
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
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut topo = Topology::FULL;
    if args.len() >= 2 && args[0] == "--topology" {
        topo = Topology::parse(&args[1]).unwrap_or_else(|e| {
            eprintln!("topo_dump: bad topology: {e}");
            std::process::exit(4)
        });
        args.drain(0..2);
    }
    let Some(path) = args.first() else {
        eprintln!("usage: topo_dump [--topology <spec>] <program.vsm | ->");
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

    let mut sim = Sim::with_topology(topo);
    let mut recs: Vec<Rec> = Vec::new();
    for (lineno, line) in &lines {
        let word = sim.words;
        let res = match line {
            Line::DebugGet { loc, count, dtype, .. } => debug_get(&sim, loc, *count, *dtype, &mut recs),
            other => match sim.exec(other) {
                Ok(()) => Ok(()),
                Err(e) => {
                    let msg = e.message();
                    if msg.starts_with("E_RANGE: ") {
                        print_records(recs);
                        eprintln!("RANGE word={word} line={lineno}: {msg}");
                        eprintln!("words={}", sim.words);
                        std::process::exit(5);
                    }
                    Err(msg)
                }
            },
        };
        if let Err(msg) = res {
            let text = src.lines().nth(lineno - 1).unwrap_or("");
            let text: String = text.chars().take(200).collect();
            eprintln!("UNSUPPORTED line {lineno}: {msg}\n  {text}");
            std::process::exit(2);
        }
    }
    print_records(recs);
    eprintln!("words={}", sim.words);
}
