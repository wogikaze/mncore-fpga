//! Reductions of the result reduction network (unit `rrn`, WP31/WP32): the L1BM reductions
//! from the PEs (`l1bmr<op>`: 16 MABs, `l1bmr4<op>`: groups of 4 MABs) and the L2BM
//! reductions from the L1BMs (`l2bmr<op>`: 8 L1Bs, `l2bmr2<op>`: pairs of L1Bs).
//!
//! One row is one element: the inputs from the reduced units, in unit order, and the result.
//! The rows are evaluated by running the instruction on the simulator (black box):
//! - `l1bmr<op> $lr0v $lb0`: input of MAB m for PE p and cycle c in GRF0 words 2c, 2c+1 of
//!   that PE; result in L1BM long word 4c + p (16 MABs) or 16c + 4g + p (group g).
//! - `l2bmr<op> $lb0 $lc0`: inputs in L1BM long word 16c + k of each L1B of the L2B; result in
//!   L2BM long word 16c + k (8 L1Bs) or 64c + 16g + k (L1Bs 2g and 2g+1).

use mncore_sim::float::Fmt;
use mncore_sim::machine::{MemWrite, PeId};
use mncore_sim::vsm::{self, MemKind};

use crate::bb::SimBackend;
use crate::official::{l1b_loc, l2b_loc, parse_dump_lines, RawJob};
use crate::rng::Rng;
use crate::values::*;
use crate::vecfile::{col, VecFile};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum RKind {
    L1,
    L1x4,
    L2,
    L2x2,
}

pub struct RrnSpec {
    pub kind: RKind,
    /// Reduction opcode, such as `ffadd` or `sbor`.
    pub op: &'static str,
}

pub const OPS: [&str; 24] = [
    "dfadd", "ffadd", "hfadd", "dmax", "fmax", "hmax", "dmin", "fmin", "hmin", "liadd", "iiadd", "siadd", "lband",
    "iband", "sband", "land", "iand", "sand", "lbor", "ibor", "sbor", "lor", "ior", "sor",
];

pub fn specs() -> Vec<RrnSpec> {
    let mut v = Vec::new();
    for kind in [RKind::L1, RKind::L1x4, RKind::L2, RKind::L2x2] {
        for op in OPS {
            v.push(RrnSpec { kind, op });
        }
    }
    v
}

const L1_UNITS: usize = mncore_sim::blocks::L1BS;
const L2_UNITS: usize = mncore_sim::blocks::L2BS;

impl RrnSpec {
    pub fn opcode(&self) -> String {
        let k = match self.kind {
            RKind::L1 => "l1bmr",
            RKind::L1x4 => "l1bmr4",
            RKind::L2 => "l2bmr",
            RKind::L2x2 => "l2bmr2",
        };
        format!("{k}{}", self.op)
    }

    pub fn stem(&self) -> String {
        self.opcode()
    }

    fn insn(&self) -> String {
        match self.kind {
            RKind::L1 | RKind::L1x4 => format!("{} $lr0v $lb0", self.opcode()),
            _ => format!("{} $lb0 $lc0", self.opcode()),
        }
    }

    pub fn inputs(&self) -> usize {
        match self.kind {
            RKind::L1 => 16,
            RKind::L1x4 => 4,
            RKind::L2 => 8,
            RKind::L2x2 => 2,
        }
    }

    fn prec(&self) -> char {
        self.op.chars().next().unwrap()
    }

    fn bits(&self) -> u32 {
        match self.prec() {
            'd' | 'l' => 64,
            'f' | 'i' => 32,
            _ => 16,
        }
    }

    fn fmt(&self) -> Option<Fmt> {
        matches!(self.prec(), 'd' | 'f' | 'h').then(|| fmt_of(self.prec()))
    }

    /// Rows per evaluated long word and long words per instruction.
    fn per_word(&self) -> usize {
        (64 / self.bits()) as usize
    }

    fn slots(&self) -> usize {
        match self.kind {
            RKind::L1 => L1_UNITS * 16,
            RKind::L1x4 => L1_UNITS * 64,
            RKind::L2 => L2_UNITS * 64,
            RKind::L2x2 => L2_UNITS * 256,
        }
    }

    pub fn template(&self) -> VecFile {
        let mut f = VecFile::default();
        f.set("unit", "rrn");
        f.set("op", self.opcode());
        f.set("rrn", self.op);
        f.set("lanebits", self.bits());
        f.set("inputs", self.inputs());
        f.set("stages", match self.kind {
            RKind::L1 => "4x4",
            _ => "1",
        });
        let d = (self.bits() / 4) as usize;
        f.cols_in = (0..self.inputs()).map(|i| col(&format!("x{i}"), d)).collect();
        f.cols_out = vec![col("z", d)];
        f
    }

    // ---- inputs ----------------------------------------------------------------------

    fn lane(&self, r: &mut Rng) -> u64 {
        match self.fmt() {
            Some(f) => float_lane(r, f),
            None => int_lane(r, self.bits()),
        }
    }

    pub fn gen_inputs(&self, n: usize, r: &mut Rng) -> (Vec<Vec<u64>>, usize) {
        let k = self.inputs();
        let w = self.bits();
        let mut rows: Vec<Vec<u64>> = Vec::new();
        match self.fmt() {
            Some(f) => {
                let fs = float_specials(f);
                let mm = man_mask(f);
                let emax = f.exp_max();
                let sb = sign_bit(f);
                // Every special value against every other, the rest zero.
                for &a in &fs {
                    for &b in &fs {
                        let mut v = vec![0u64; k];
                        v[0] = a;
                        v[k - 1] = b;
                        rows.push(v);
                    }
                }
                for case in 0..10 * 16 {
                    let e0 = r.range(f.man_bits as i64 + 6, emax as i64 - 3) as u64;
                    let v: Vec<u64> = match case % 10 {
                        // Exponent differences 0, 1, 2, ... from the largest (alignment and
                        // rounding of each element, SDM 4.2.1).
                        0 => (0..k).map(|i| fbits(f, r.chance(1, 2), e0.saturating_sub(i as u64 * r.below(3)).max(1), r.bits(f.man_bits))).collect(),
                        // Ties in the alignment: shifted-out bits exactly one half (with 3 guard bits).
                        1 => (0..k)
                            .map(|i| {
                                if i == 0 {
                                    return fbits(f, false, e0, r.bits(f.man_bits));
                                }
                                let d = r.range(4, 8) as u32;
                                let sig = (((1u64 << f.man_bits) | r.bits(f.man_bits)) >> (d - 3) << (d - 3)) | (1u64 << (d - 4));
                                fbits(f, r.chance(1, 2), e0 - d as u64, sig & mm)
                            })
                            .collect(),
                        // x and -x: exact cancellation.
                        2 => {
                            let mut v: Vec<u64> = (0..k / 2).map(|_| fbits(f, false, r.range(1, emax as i64 - 1) as u64, r.bits(f.man_bits))).collect();
                            let neg: Vec<u64> = v.iter().map(|x| x ^ sb).collect();
                            v.extend(neg);
                            v.resize(k, 0);
                            v
                        }
                        // Near cancellation: the sum is tiny (underflow).
                        3 => {
                            let a = fbits(f, false, r.range(1, 4) as u64, r.bits(f.man_bits));
                            let mut v = vec![0u64; k];
                            v[0] = a;
                            v[1] = (a ^ sb).wrapping_add(r.range(-3, 3) as u64) & mask(w);
                            v
                        }
                        // Large values: the sum overflows.
                        4 => (0..k).map(|_| fbits(f, false, emax - 1 - r.below(2), mm - r.below(4))).collect(),
                        // Infinities of both signs mixed with finite values.
                        5 => (0..k).map(|_| if r.chance(1, 3) { fbits(f, r.chance(1, 2), emax, r.bits(f.man_bits) * r.below(2)) } else { float_lane(r, f) }).collect(),
                        // Zeros of both signs (also with nonzero mantissas).
                        6 => (0..k).map(|_| fbits(f, r.chance(1, 2), 0, if r.chance(1, 2) { r.bits(f.man_bits) } else { 0 })).collect(),
                        // All equal.
                        7 => vec![float_lane(r, f); k],
                        // Values that differ in sign only or by one ulp (max/min order).
                        8 => {
                            let a = float_lane(r, f);
                            (0..k).map(|_| match r.below(4) {
                                0 => a ^ sb,
                                1 => a ^ 1,
                                2 => a,
                                _ => (a ^ sb) ^ 1,
                            })
                            .collect()
                        }
                        _ => (0..k).map(|_| float_lane(r, f)).collect(),
                    };
                    rows.push(v);
                }
            }
            None => {
                let s = int_specials(w);
                for &a in &s {
                    for &b in &s {
                        let mut v = vec![0u64; k];
                        v[0] = a;
                        v[k - 1] = b;
                        rows.push(v);
                    }
                }
                for _ in 0..64 {
                    rows.push(vec![mask(w); k]);
                    rows.push((0..k).map(|_| r.pick(&s)).collect());
                    rows.push((0..k).map(|i| 1u64 << ((i as u32 * 5) % w)).collect());
                }
            }
        }
        let edge = rows.len();
        for _ in 0..n {
            rows.push((0..k).map(|_| self.lane(r)).collect());
        }
        (rows, edge)
    }

    // ---- evaluation --------------------------------------------------------------------

    /// Where row slot `s` reads its inputs and writes its result:
    /// (unit index, address) of every input, and (unit index, address) of the result.
    fn slot_layout(&self, s: usize) -> (Vec<(usize, usize)>, (usize, usize)) {
        match self.kind {
            RKind::L1 => {
                let (l1b, p, c) = (s / 16, (s % 16) / 4, s % 4);
                let ins = (0..16).map(|m| (l1b * 64 + m * 4 + p, c)).collect();
                (ins, (l1b, 4 * c + p))
            }
            RKind::L1x4 => {
                let (l1b, rem) = (s / 64, s % 64);
                let (g, p, c) = (rem / 16, (rem % 16) / 4, rem % 4);
                let ins = (0..4).map(|j| (l1b * 64 + (4 * g + j) * 4 + p, c)).collect();
                (ins, (l1b, 16 * c + 4 * g + p))
            }
            RKind::L2 => {
                let (l2b, a) = (s / 64, s % 64);
                let ins = (0..8).map(|b| (l2b * 8 + b, a)).collect();
                (ins, (l2b, a))
            }
            RKind::L2x2 => {
                let (l2b, rem) = (s / 256, s % 256);
                let (g, a) = (rem / 64, rem % 64);
                let (c, k) = (a / 16, a % 16);
                let ins = (0..2).map(|j| (l2b * 8 + 2 * g + j, a)).collect();
                (ins, (l2b, 64 * c + 16 * g + k))
            }
        }
    }

    /// Input long words per (unit, address) and the slots of a chunk of rows.
    fn pack(&self, rows: &[&Vec<u64>]) -> Vec<((usize, usize), u64)> {
        let per = self.per_word();
        let w = self.bits();
        let mut words: std::collections::BTreeMap<(usize, usize), u64> = Default::default();
        for (s, chunk) in rows.chunks(per).enumerate() {
            let (ins, _) = self.slot_layout(s);
            for (i, loc) in ins.iter().enumerate() {
                let lanes: Vec<u64> = chunk.iter().map(|row| row[i]).collect();
                words.insert(*loc, pack_lanes(&lanes, w));
            }
        }
        words.into_iter().collect()
    }

    fn unpack(&self, n_rows: usize, mut result: impl FnMut(usize, usize) -> u64) -> Vec<u64> {
        let per = self.per_word();
        let w = self.bits();
        (0..n_rows)
            .map(|i| {
                let (s, lane) = (i / per, i % per);
                let (_, (unit, addr)) = self.slot_layout(s);
                let v = result(unit, addr);
                (v >> (64 - w * (lane as u32 + 1))) & mask(w)
            })
            .collect()
    }

    fn capacity(&self) -> usize {
        self.slots() * self.per_word()
    }

    /// Runs the rows on the simulator and returns the results.
    pub fn run_sim(&self, sb: &mut SimBackend, rows: &[&Vec<u64>]) -> Result<Vec<u64>, String> {
        let mut out = Vec::new();
        for chunk in rows.chunks(self.capacity()) {
            let sim = sb.sim_mut();
            for ((unit, addr), v) in self.pack(chunk) {
                match self.kind {
                    RKind::L1 | RKind::L1x4 => {
                        sim.m.mem.poke(MemKind::Grf0, unit, 2 * addr, (v >> 32) as u32);
                        sim.m.mem.poke(MemKind::Grf0, unit, 2 * addr + 1, v as u32);
                    }
                    _ => sim.m.blocks.l1bm[unit][addr] = v,
                }
            }
            // Poison the results so that an unwritten one is noticed.
            for s in 0..chunk.len().div_ceil(self.per_word()) {
                let (_, (unit, addr)) = self.slot_layout(s);
                match self.kind {
                    RKind::L1 | RKind::L1x4 => sim.m.blocks.l1bm[unit][addr] = 0xdead_beef_dead_beef,
                    _ => sim.m.blocks.l2bm[unit][addr] = 0xdead_beef_dead_beef,
                }
            }
            let lines = vsm::parse(&self.insn()).map_err(|e| e.to_string())?;
            for (_, l) in &lines {
                sim.exec(l).map_err(|e| format!("`{}`: {}", self.insn(), e.message()))?;
            }
            let l1 = matches!(self.kind, RKind::L1 | RKind::L1x4);
            out.extend(self.unpack(chunk.len(), |unit, addr| {
                if l1 { sim.m.blocks.l1bm[unit][addr] } else { sim.m.blocks.l2bm[unit][addr] }
            }));
        }
        Ok(out)
    }

    /// VSM programs for the official tools, one per chunk of rows.
    pub fn official_jobs(&self, rows: &[&Vec<u64>]) -> Vec<RawJob> {
        let mut jobs = Vec::new();
        for (ci, chunk) in rows.chunks(self.capacity()).enumerate() {
            let mut vsm = String::new();
            let words = self.pack(chunk);
            let mut units: Vec<usize> = Vec::new();
            match self.kind {
                RKind::L1 | RKind::L1x4 => {
                    let mut per_pe: std::collections::BTreeMap<usize, [u64; 4]> = Default::default();
                    for ((pe, c), v) in &words {
                        per_pe.entry(*pe).or_insert([0; 4])[*c] = *v;
                    }
                    for (pe, v) in &per_pe {
                        vsm += &format!("d set $lr0{} 4 {}\n", PeId::from_index(*pe).name(), v.iter().map(|x| format!("{x:016x}")).collect::<String>());
                        units.push(pe / 64);
                    }
                }
                _ => {
                    let mut per_l1b: std::collections::BTreeMap<usize, [u64; 64]> = Default::default();
                    for ((l1b, a), v) in &words {
                        per_l1b.entry(*l1b).or_insert([0; 64])[*a] = *v;
                    }
                    for (l1b, v) in &per_l1b {
                        vsm += &format!("d set $lb0{} 64 {}\n", l1b_loc(*l1b), v.iter().map(|x| format!("{x:016x}")).collect::<String>());
                        units.push(l1b / 8);
                    }
                }
            }
            units.dedup();
            vsm += &format!("{}\nnop/3\n", self.insn());
            for u in units {
                vsm += &match self.kind {
                    RKind::L1 => format!("d get $lb0{} 16\n", l1b_loc(u)),
                    RKind::L1x4 => format!("d get $lb0{} 64\n", l1b_loc(u)),
                    RKind::L2 => format!("d get $lc0{} 64\n", l2b_loc(u)),
                    RKind::L2x2 => format!("d get $lc0{} 256\n", l2b_loc(u)),
                };
            }
            jobs.push(RawJob { name: format!("{}_{ci}", self.stem()), vsm, insns: vec![self.insn()] });
        }
        jobs
    }

    /// Results of the rows from the dumps of `official_jobs`.
    pub fn parse_official(&self, rows: &[&Vec<u64>], dumps: &[String]) -> Result<Vec<u64>, String> {
        let mut out = Vec::new();
        for (chunk, dump) in rows.chunks(self.capacity()).zip(dumps) {
            let mut vals: std::collections::HashMap<(usize, usize), u64> = Default::default();
            for l in parse_dump_lines(dump)? {
                let unit = match self.kind {
                    RKind::L1 | RKind::L1x4 => (0..L1_UNITS).find(|&b| l1b_loc(b) == l.pe),
                    _ => (0..L2_UNITS).find(|&b| l2b_loc(b) == l.pe),
                }
                .ok_or_else(|| format!("unexpected location {} ({})", l.pe, l.mem))?;
                vals.insert((unit, l.addr as usize), l.value);
            }
            let mut missing = None;
            let got = self.unpack(chunk.len(), |unit, addr| match vals.get(&(unit, addr)) {
                Some(v) => *v,
                None => {
                    missing = Some((unit, addr));
                    0
                }
            });
            if let Some((u, a)) = missing {
                return Err(format!("no result for unit {u} address {a}"));
            }
            out.extend(got);
        }
        Ok(out)
    }
}

pub fn generate(spec: &RrnSpec, n: usize, seed: u64, sb: &mut SimBackend) -> Result<VecFile, String> {
    let mut r = Rng::for_stream(seed, &format!("rrn/{}", spec.stem()));
    let (ins, edge) = spec.gen_inputs(n, &mut r);
    let refs: Vec<&Vec<u64>> = ins.iter().collect();
    let outs = spec.run_sim(sb, &refs)?;
    let mut f = spec.template();
    f.set("sdm", "yes");
    f.set("seed", seed);
    f.set("edge", edge);
    f.set("rows", ins.len());
    f.rows = ins
        .into_iter()
        .zip(outs)
        .map(|(i, o)| (i.into_iter().map(|x| x as u128).collect(), vec![o as u128]))
        .collect();
    Ok(f)
}
