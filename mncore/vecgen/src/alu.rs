//! ALU instructions (SDM 3.6.12): unit `alu` (integer and bit operations, WP11) and unit
//! `fpalu` (floating-point ALU operations and block-float conversion, WP13).
//!
//! Every instruction reads x from GRF0 and y from GRF1 with two-long-word access and writes
//! LM1 and mask entry 1. One row is one (PE, cycle) slot: the two 128-bit input buses, the
//! 128-bit result and the 4 mask flags of that cycle.

use mncore_sim::float::{self, Fmt, HALF, SINGLE};

use crate::bb::{bus, hi, lo, Block, Item, ItemOut, DST, SRC};
use crate::rng::Rng;
use crate::spec::{fields, plan_items, yes, Plan, RowItem, Spec, ALL_SUBS};
use crate::values::*;
use crate::vecfile::{col, VecFile};

pub struct AluDef {
    pub name: &'static str,
    pub inputs: usize,
    pub aluop: &'static str,
    /// iselb is part of the opcode (multiplexed instructions, Scrapbox "多重化される ALU 命令").
    pub iselb: Option<&'static str>,
    /// The SDM documents the `u` option for this operation.
    pub u_sdm: bool,
}

const fn def(name: &'static str, inputs: usize, aluop: &'static str, iselb: Option<&'static str>, u_sdm: bool) -> AluDef {
    AluDef { name, inputs, aluop, iselb, u_sdm }
}

/// Integer and bit operations with precisions l, i, s (aluop values from the assembler).
pub const INT_OPS: [AluDef; 17] = [
    def("add", 2, "00000", None, true),
    def("sub", 2, "00001", None, true),
    def("inc", 1, "00010", None, true),
    def("dec", 1, "00011", None, true),
    def("not", 1, "00100", None, false),
    def("and", 2, "00101", None, false),
    def("or", 2, "00110", None, false),
    def("xor", 2, "00111", None, false),
    def("max", 2, "01000", None, true),
    def("min", 2, "01001", None, true),
    def("passa", 1, "01010", None, false),
    def("lsl", 2, "01011", None, false),
    def("lsr", 2, "01100", None, true),
    def("bsl", 2, "01101", None, false),
    def("bsr", 2, "01110", None, false),
    def("lnot", 1, "01111", None, false),
    def("packbit", 2, "10011", None, false),
];

/// Floating-point operations with precisions d, f, h.
pub const FLOAT_OPS: [AluDef; 14] = [
    def("passa", 1, "01010", None, false),
    def("rsqrt", 1, "10000", None, false),
    def("packbit", 2, "10011", None, false),
    def("relu", 2, "10100", None, false),
    def("relu1", 2, "10101", None, false),
    def("relu2", 2, "10110", None, false),
    def("relu3", 2, "10111", None, false),
    def("lrelud", 2, "11000", None, false),
    def("lreluo", 2, "11001", None, false),
    def("ilrelud", 2, "11010", None, false),
    def("max", 2, "11011", None, false),
    def("min", 2, "11100", None, false),
    def("floor", 1, "11110", Some("110"), false),
    def("ftoi", 1, "11110", Some("111"), true),
];

#[derive(Clone, Copy)]
pub enum Kind {
    Lane(&'static AluDef),
    /// Block-float conversion: `bfn` (d/f/g, or h with mantissa length n) or `bfe` (h only).
    Bf { ext: bool, n: u8 },
    Zero,
    Imm { u: bool },
}

pub struct AluSpec {
    pub unit: &'static str,
    pub kind: Kind,
    pub prec: char,
    pub unsigned: bool,
    /// Rows use the `r` input option (single to half rounding of x and/or y).
    pub r: bool,
}

pub fn specs(unit: &'static str) -> Vec<Box<dyn Spec>> {
    let mut v: Vec<Box<dyn Spec>> = Vec::new();
    let mut push = |kind: Kind, prec: char| {
        for unsigned in [false, true] {
            // The assembler accepts the `r` input option with every precision, but the
            // emulator stops with "ialuc.rounda can be used only with half-word" unless the
            // precision is a half word (dmode 10: h or s).
            for r in [false, true] {
                if r && !matches!(prec, 'h' | 's') {
                    continue;
                }
                v.push(Box::new(AluSpec { unit, kind, prec, unsigned, r }));
            }
        }
    };
    if unit == "alu" {
        for d in &INT_OPS {
            for p in ['l', 'i', 's'] {
                push(Kind::Lane(d), p);
            }
        }
        v.push(Box::new(AluSpec { unit, kind: Kind::Zero, prec: 's', unsigned: false, r: false }));
        v.push(Box::new(AluSpec { unit, kind: Kind::Imm { u: false }, prec: 'l', unsigned: false, r: false }));
        v.push(Box::new(AluSpec { unit, kind: Kind::Imm { u: true }, prec: 'l', unsigned: false, r: false }));
    } else {
        for d in &FLOAT_OPS {
            for p in ['d', 'f', 'h'] {
                push(Kind::Lane(d), p);
            }
        }
        // `ugbfn` is rejected by the assembler (`udbfn` and `ufbfn` are accepted).
        for p in ['d', 'f'] {
            push(Kind::Bf { ext: false, n: 0 }, p);
        }
        v.push(Box::new(AluSpec { unit, kind: Kind::Bf { ext: false, n: 0 }, prec: 'g', unsigned: false, r: false }));
        // `uhbfn/<n>` and `uhbfe/<n>` are accepted by the assembler but not by the simulator's
        // parser (it reads `/<n>` as a mask), so only the forms without `u` are generated.
        for ext in [false, true] {
            for n in 6..=9 {
                for r in [false, true] {
                    v.push(Box::new(AluSpec { unit, kind: Kind::Bf { ext, n }, prec: 'h', unsigned: false, r }));
                }
            }
        }
    }
    v
}

fn lane_bits(p: char) -> u32 {
    match p {
        'l' | 'd' => 64,
        's' | 'h' => 16,
        _ => 32,
    }
}

fn dmode(p: char) -> &'static str {
    match p {
        'l' | 'd' => "00",
        'i' | 'f' => "01",
        's' | 'h' => "10",
        _ => "11",
    }
}

const IMM_EDGE: [u64; 16] = [
    0, 1, 0xffff_ffff, 0x8000_0000, 0x7fff_ffff, 0x1234_5678, 0xdead_beef, 0x3f80_0000, 0xbf80_0000,
    0x3e00_3e00, 0x0001_0001, 0xffff_0000, 0x0000_ffff, 0x8000_0001, 0x5555_5555, 0xaaaa_aaaa,
];

impl AluSpec {
    fn u(&self) -> &'static str {
        if self.unsigned { "u" } else { "" }
    }

    pub fn opcode(&self) -> String {
        match self.kind {
            Kind::Lane(d) => format!("{}{}{}", self.u(), self.prec, d.name),
            Kind::Bf { ext, n } if self.prec == 'h' => {
                format!("{}h{}/{}", self.u(), if ext { "bfe" } else { "bfn" }, n)
            }
            Kind::Bf { .. } => format!("{}{}bfn", self.u(), self.prec),
            Kind::Zero => "zero".into(),
            Kind::Imm { u } => (if u { "immu" } else { "imm" }).into(),
        }
    }

    fn inputs(&self) -> usize {
        match self.kind {
            Kind::Lane(d) => d.inputs,
            Kind::Bf { .. } => 1,
            _ => 0,
        }
    }

    fn aluop(&self) -> &'static str {
        match self.kind {
            Kind::Lane(d) => d.aluop,
            Kind::Bf { ext: true, .. } | Kind::Zero => "11101",
            Kind::Bf { .. } => "11110",
            Kind::Imm { .. } => "11111",
        }
    }

    fn iselb(&self) -> Option<String> {
        match self.kind {
            Kind::Lane(d) => d.iselb.map(String::from),
            Kind::Bf { n, .. } if self.prec == 'h' => Some(format!("{:03b}", 9 - n)),
            Kind::Bf { .. } | Kind::Zero => Some("000".into()),
            Kind::Imm { .. } => None,
        }
    }

    fn is_unsigned(&self) -> bool {
        match self.kind {
            Kind::Zero => true,
            Kind::Imm { u } => u,
            _ => self.unsigned,
        }
    }

    fn insn(&self, ra: bool, rb: bool, imm: u64) -> String {
        let rs = |b: bool| if b { "r" } else { "" };
        match self.kind {
            Kind::Zero => format!("zero {DST}"),
            Kind::Imm { .. } => format!("{} ui\"0x{:08x}\" {DST}", self.opcode(), imm),
            _ if self.inputs() == 2 => format!("{} {}{} {}{} {DST}", self.opcode(), SRC[0], rs(ra), SRC[1], rs(rb)),
            _ => format!("{} {}{} {DST}", self.opcode(), SRC[0], rs(ra)),
        }
    }

    fn expect_fields(&self, ra: bool, rb: bool) -> Vec<(String, String)> {
        let mut v = fields(&[("pe.aluc.aluop", self.aluop()), ("pe.aluc.is_unsigned", yes(self.is_unsigned()))]);
        if !matches!(self.kind, Kind::Imm { .. }) {
            v.extend(fields(&[
                ("pe.aluc.dmode", if matches!(self.kind, Kind::Zero) { "10" } else { dmode(self.prec) }),
                ("pe.aluc.rounda", yes(ra)),
                ("pe.aluc.roundb", yes(rb)),
            ]));
        }
        if let Some(s) = self.iselb() {
            v.push(("pe.aluc.iselb".into(), s));
        }
        if matches!(self.kind, Kind::Zero) {
            v.push(("pe.aluc.isela".into(), "0101".into()));
        }
        v
    }

    fn fmt(&self) -> Fmt {
        fmt_of(self.prec)
    }

    /// Combinations of the `r` options used by the rows.
    fn round_combos(&self) -> Vec<(bool, bool)> {
        if !self.r {
            vec![(false, false)]
        } else if self.inputs() == 2 {
            vec![(true, false), (false, true), (true, true)]
        } else {
            vec![(true, false)]
        }
    }

    // ---- lane operations ------------------------------------------------------------

    /// Edge-case lane pairs (x, y) in the lane width of the precision.
    fn edge_pairs(&self, d: &AluDef, r: &mut Rng) -> Vec<(u64, u64)> {
        let w = lane_bits(self.prec);
        let mut v = Vec::new();
        if self.unit == "alu" {
            let s = int_specials(w);
            if d.inputs == 2 {
                for &x in &s {
                    for &y in &s {
                        v.push((x, y));
                    }
                }
            } else {
                v.extend(s.iter().map(|&x| (x, 0)));
            }
            if matches!(d.name, "lsl" | "lsr" | "bsl" | "bsr") {
                let m = mask(w);
                let xs = [1u64, m, (m >> 1) + 2, 0x0123_4567_89ab_cdef & m, 0x8000_0000_0000_0001 & m | (1 << (w - 1))];
                for &x in &xs {
                    for sh in 0..=(2 * w as u64 + 2) {
                        v.push((x, sh));
                    }
                    for k in 1..=4u64 {
                        v.push((x, (2 * w as u64 * k * 7 + k) & m));
                    }
                }
            }
            return v;
        }
        let f = self.fmt();
        let fs = float_specials(f);
        let mm = man_mask(f);
        let emax = f.exp_max();
        let b = f.bias() as u64;
        let mb = f.man_bits as i64;
        let signb = sign_bit(f);
        match d.name {
            "max" | "min" => {
                for &x in &fs {
                    for &y in &fs {
                        v.push((x, y));
                    }
                }
                for &x in &fs {
                    v.push((x, x ^ 1));
                    v.push((x, x ^ signb));
                    v.push((x, x ^ (1 << f.man_bits)));
                }
            }
            "relu" | "relu1" | "relu2" | "relu3" => {
                for top in 0..16u64 {
                    let x = (top << (f.width() - 4)) | r.bits(f.width() - 4);
                    for &y in &fs {
                        v.push((x, y));
                    }
                }
            }
            "lrelud" | "lreluo" | "ilrelud" => {
                let xs = [one(f), one(f) | signb, 0, signb];
                for e in exp_sweep(f) {
                    for m in [0, 1, mm, r.next_u64() & mm] {
                        for neg in [false, true] {
                            for &x in &xs {
                                v.push((x, fbits(f, neg, e, m)));
                            }
                        }
                    }
                }
            }
            "floor" | "ftoi" => {
                let top = if d.name == "floor" { mb + 2 } else { lane_bits(self.prec) as i64 + 2 };
                for unb in -3..=top {
                    for m in [0, 1, mm, 1 << (mb - 1), (1 << (mb - 1)) | 1, r.next_u64() & mm] {
                        for neg in [false, true] {
                            if let Some(x) = fnormal(f, neg, unb, m) {
                                v.push((x, 0));
                            }
                        }
                    }
                }
                v.extend(fs.iter().map(|&x| (x, 0)));
            }
            "rsqrt" => {
                let mut es = vec![0, 1, 2, 3, b - 2, b - 1, b, b + 1, b + 2, emax - 2, emax - 1, emax];
                es.dedup();
                for top in 0..16u64 {
                    for &e in &es {
                        for neg in [false, true] {
                            let m = (top << (f.man_bits - 4)) | r.bits(f.man_bits - 4);
                            v.push((fbits(f, neg, e, m), 0));
                        }
                    }
                }
            }
            "packbit" => {
                for &x in &fs {
                    for &y in &float_small(f) {
                        v.push((x, y));
                    }
                }
            }
            _ => {
                v.extend(fs.iter().map(|&x| (x, 0)));
            }
        }
        v
    }

    fn random_pair(&self, d: &AluDef, r: &mut Rng) -> (u64, u64) {
        let w = lane_bits(self.prec);
        if self.unit == "alu" {
            return match d.name {
                "lsl" | "lsr" | "bsl" | "bsr" => (int_lane(r, w), shift_count(r, w)),
                _ if d.inputs == 2 => int_pair(r, w),
                _ => (int_lane(r, w), 0),
            };
        }
        let f = self.fmt();
        match d.name {
            "max" | "min" => {
                let x = float_lane(r, f);
                let y = match r.below(8) {
                    0 => x,
                    1 => x ^ sign_bit(f),
                    2 => x ^ 1,
                    3 => (x & sign_bit(f)) | r.bits(f.width() - 1),
                    _ => float_lane(r, f),
                };
                (x, y)
            }
            "relu" | "relu1" | "relu2" | "relu3" | "lrelud" | "lreluo" | "ilrelud" => {
                let x = if r.chance(1, 2) { r.bits(f.width()) } else { float_lane(r, f) };
                (x, float_lane(r, f))
            }
            "floor" | "ftoi" => {
                let top = if d.name == "floor" { f.man_bits as i64 + 2 } else { w as i64 + 2 };
                let x = if r.chance(1, 2) {
                    fnormal(f, r.chance(1, 2), r.range(-3, top), r.bits(f.man_bits)).unwrap_or(0)
                } else {
                    float_lane(r, f)
                };
                (x, 0)
            }
            "packbit" => (r.bits(w), r.bits(w)),
            _ => (float_lane(r, f), 0),
        }
    }

    /// Builds rows from lane pairs. An operand with the `r` option gets four singles from
    /// `single` instead of lanes.
    fn lane_rows(&self, pairs: &[(u64, u64)], ra: bool, rb: bool, single: &mut dyn FnMut(&mut Rng) -> u64, r: &mut Rng) -> Vec<Vec<u128>> {
        let w = lane_bits(self.prec);
        let per = (64 / w) as usize;
        let two = self.inputs() == 2;
        let mut rows = Vec::new();
        for chunk in pairs.chunks(per) {
            let xs: Vec<u64> = chunk.iter().map(|p| p.0).collect();
            let ys: Vec<u64> = chunk.iter().map(|p| p.1).collect();
            let mut singles = |r: &mut Rng| -> u128 {
                let v: Vec<u64> = (0..4).map(|_| single(r)).collect();
                bus((v[0] << 32) | v[1], (v[2] << 32) | v[3])
            };
            let x = if ra { singles(r) } else { bus(pack_lanes(&xs, w), r.next_u64()) };
            let y = if rb {
                singles(r)
            } else if two {
                bus(pack_lanes(&ys, w), r.next_u64())
            } else {
                // y is not an operand of one-input instructions: random filler.
                r.next_u128()
            };
            rows.push(vec![ra as u128, rb as u128, hi(x) as u128, lo(x) as u128, hi(y) as u128, lo(y) as u128]);
        }
        rows
    }

    fn gen_lane(&self, d: &'static AluDef, n: usize, r: &mut Rng) -> (Vec<Vec<u128>>, usize) {
        let mut rows = Vec::new();
        let combos = self.round_combos();
        let list = f2h_specials();
        let per = (64 / lane_bits(self.prec)) as usize;
        let pairs = self.edge_pairs(d, r);
        let quad = |v: [u64; 4]| bus((v[0] << 32) | v[1], (v[2] << 32) | v[3]);
        for &(ra, rb) in &combos {
            if ra && rb {
                // Every pair of rounding special values, as x and y lanes.
                let n2 = list.len();
                let total = n2 * n2;
                for c in 0..total.div_ceil(4) {
                    let x = quad([0, 1, 2, 3].map(|q| list[((4 * c + q) % total) / n2]));
                    let y = quad([0, 1, 2, 3].map(|q| list[((4 * c + q) % total) % n2]));
                    rows.push(vec![1, 1, hi(x) as u128, lo(x) as u128, hi(y) as u128, lo(y) as u128]);
                }
            } else if ra || rb {
                // The rounded operand cycles through the rounding special values; the other
                // takes the edge pairs. Enough rows for both lists.
                let want = pairs.len().max(list.len().div_ceil(4) * per);
                let ext: Vec<(u64, u64)> = (0..want).map(|i| pairs[i % pairs.len()]).collect();
                let mut k = 0usize;
                let mut next = |_: &mut Rng| {
                    k += 1;
                    list[(k - 1) % list.len()]
                };
                rows.extend(self.lane_rows(&ext, ra, rb, &mut next, r));
            } else {
                let mut none = |_: &mut Rng| 0u64;
                rows.extend(self.lane_rows(&pairs, false, false, &mut none, r));
            }
        }
        let edge = rows.len();
        let mut rand_single = |r: &mut Rng| f2h_lane(r);
        for i in 0..n {
            let (ra, rb) = combos[i % combos.len()];
            let pairs: Vec<(u64, u64)> = (0..per).map(|_| self.random_pair(d, r)).collect();
            rows.extend(self.lane_rows(&pairs, ra, rb, &mut rand_single, r));
        }
        (rows, edge)
    }

    // ---- block float --------------------------------------------------------------------

    /// Mantissa bits kept by the conversion and the format of the block elements.
    fn bf_keep(&self) -> (Fmt, u32) {
        match (self.prec, self.kind) {
            ('h', Kind::Bf { n, .. }) => (HALF, n as u32),
            ('g', _) => (SINGLE, 18),
            (p, _) => (fmt_of(p), fmt_of(p).man_bits),
        }
    }

    /// One block of `len` raw values for edge case `case` (see FORMAT.md).
    fn bf_block(&self, f: Fmt, keep: u32, len: usize, case: usize, r: &mut Rng) -> Vec<u64> {
        let emax = f.exp_max() as i64;
        let m = f.man_bits;
        let mm = man_mask(f);
        let drop = m - keep;
        let top_ones = |r: &mut Rng| (mm >> drop << drop) | r.bits(drop.max(1)) & ((1u64 << drop) - 1);
        let rm = |r: &mut Rng| r.next_u64() & mm;
        let e0 = r.range(20.min(emax - 2), emax - 2);
        let mut v: Vec<u64> = (0..len)
            .map(|_| fbits(f, r.chance(1, 2), (e0 - r.range(0, 4)).max(1) as u64, rm(r)))
            .collect();
        let i0 = r.below(len as u64) as usize;
        match case % 12 {
            // All exponents zero (some mantissas nonzero): everything becomes zero.
            0 => {
                for x in v.iter_mut() {
                    *x = fbits(f, r.chance(1, 2), 0, if r.chance(1, 2) { rm(r) } else { 0 });
                }
            }
            // An infinity: the common exponent is infinity.
            1 => v[i0] = fbits(f, r.chance(1, 2), emax as u64, if r.chance(1, 2) { 1 } else { 0 }),
            // The largest element has all kept mantissa bits set: common exponent + 1.
            2 => {
                let e = (e0 + 1).min(emax - 1) as u64;
                v[i0] = fbits(f, r.chance(1, 2), e, top_ones(r));
            }
            // Near the top of the range: common exponent (+ dropped bits) reaches infinity.
            3 => {
                for x in v.iter_mut() {
                    let e = (emax - 1 - r.range(0, drop as i64 + 1)).max(1) as u64;
                    *x = fbits(f, r.chance(1, 2), e, if r.chance(1, 3) { mm } else { rm(r) });
                }
            }
            // Exponent differences 0, 1, 2, ... from the largest element.
            4 => {
                let base = r.range(m as i64 + 8, emax - 1).min(emax - 1);
                let step = r.range(1, 2);
                for (i, x) in v.iter_mut().enumerate() {
                    let e = (base - step * i as i64).max(1) as u64;
                    *x = fbits(f, r.chance(1, 2), e, rm(r));
                }
            }
            // Exponent differences around 6 below the largest element: the extended
            // representation boundary of hbfe (common exponent - exponent around 6 + dropped).
            5 => {
                let base = r.range(12 + drop as i64, emax - 2);
                v[0] = fbits(f, false, base as u64, rm(r));
                for x in v.iter_mut().skip(1) {
                    let d = 6 + r.range(-1, 1);
                    let mant = if r.chance(1, 2) { top_ones(r) } else { rm(r) };
                    *x = fbits(f, r.chance(1, 2), (base - d).max(1) as u64, mant);
                }
            }
            // Zero elements mixed with normal ones.
            6 => {
                for x in v.iter_mut() {
                    if r.chance(1, 2) {
                        *x = fbits(f, r.chance(1, 2), 0, if r.chance(1, 2) { rm(r) } else { 0 });
                    }
                }
            }
            // Rounding ties: the bits shifted out are exactly one half.
            7 => {
                let base = r.range(m as i64 + 4, emax - 2);
                v[0] = fbits(f, false, base as u64, rm(r));
                for x in v.iter_mut().skip(1) {
                    let d = r.range(1, 4) as u32;
                    // The significand is shifted right by d + 1 + dropped bits (for half the
                    // dropped bits are in the common exponent). Make those bits 10..0.
                    let sh = d + 1 + drop;
                    let sig = (((1u64 << m) | rm(r)) >> sh << sh) | (1u64 << (sh - 1));
                    *x = fbits(f, r.chance(1, 2), (base - d as i64).max(1) as u64, sig & mm);
                }
            }
            // All the same exponent.
            8 => {
                for x in v.iter_mut() {
                    *x = fbits(f, r.chance(1, 2), e0 as u64, rm(r));
                }
            }
            // Tiny values only (small exponents, underflow of the shifted mantissas).
            9 => {
                for x in v.iter_mut() {
                    *x = fbits(f, r.chance(1, 2), r.range(1, 3 + drop as i64) as u64, rm(r));
                }
            }
            // Wide spread of exponents.
            10 => {
                for x in v.iter_mut() {
                    *x = fbits(f, r.chance(1, 2), r.range(1, emax - 1) as u64, rm(r));
                }
            }
            // Special values anywhere.
            _ => {
                let fs = float_specials(f);
                for x in v.iter_mut() {
                    if r.chance(1, 3) {
                        *x = r.pick(&fs);
                    }
                }
            }
        }
        v
    }

    /// Four PE buses holding the blocks of one conversion.
    fn bf_buses(&self, case: usize, r: &mut Rng) -> [u128; 4] {
        let (f, keep) = self.bf_keep();
        match self.prec {
            'd' => {
                let b = self.bf_block(f, keep, 4, case, r);
                [0, 1, 2, 3].map(|p| bus(b[p], r.next_u64()))
            }
            'f' => {
                let a = self.bf_block(f, keep, 4, case, r);
                let c = self.bf_block(f, keep, 4, case + 5, r);
                [0, 1, 2, 3].map(|p| bus((a[p] << 32) | c[p], r.next_u64()))
            }
            'g' => {
                let b = self.bf_block(f, keep, 8, case, r);
                [0, 1, 2, 3].map(|p| bus((b[2 * p] << 32) | b[2 * p + 1], r.next_u64()))
            }
            _ => {
                let a = self.bf_block(f, keep, 16, case, r);
                let c = self.bf_block(f, keep, 16, case + 5, r);
                [0, 1, 2, 3].map(|p| bus(pack_lanes(&a[4 * p..4 * p + 4], 16), pack_lanes(&c[4 * p..4 * p + 4], 16)))
            }
        }
    }

    /// Four PE buses of singles that round to interesting half blocks (`r` option).
    fn bf_round_buses(&self, case: usize, r: &mut Rng) -> [u128; 4] {
        let n = match self.kind {
            Kind::Bf { n, .. } if self.prec == 'h' => n as u32,
            _ => 9,
        };
        let h = self.bf_block(HALF, n, 16, case, r);
        let specials = f2h_specials();
        let single = |x: u64, r: &mut Rng| -> u64 {
            // Some elements are rounding special values (-0, underflow, overflow, ties).
            if r.chance(1, 6) {
                return r.pick(&specials);
            }
            let s = float::encode(SINGLE, float::decode(HALF, x)) | ((x >> 15) << 31);
            let e = (s >> 23) & 0xff;
            if e == 0 || e == 255 { s | (r.bits(23) & if r.chance(1, 2) { 0 } else { 0x7f_ffff }) } else { s | r.bits(14) }
        };
        [0, 1, 2, 3].map(|p| {
            let v: Vec<u64> = (0..4).map(|k| single(h[4 * p + k], r)).collect();
            bus((v[0] << 32) | v[1], (v[2] << 32) | v[3])
        })
    }

    fn gen_bf(&self, n: usize, r: &mut Rng) -> (Vec<Vec<u128>>, usize) {
        let mut rows = Vec::new();
        let row = |ra: bool, b: [u128; 4]| -> Vec<u128> {
            let mut v = vec![ra as u128];
            for x in b {
                v.push(hi(x) as u128);
                v.push(lo(x) as u128);
            }
            v
        };
        let ra = self.r;
        for case in 0..12 * 16 {
            let b = if ra { self.bf_round_buses(case, r) } else { self.bf_buses(case, r) };
            rows.push(row(ra, b));
        }
        let edge = rows.len();
        for _ in 0..n {
            let case = r.below(12) as usize;
            let b = if ra { self.bf_round_buses(case, r) } else { self.bf_buses(case, r) };
            rows.push(row(ra, b));
        }
        (rows, edge)
    }

    fn plan_bf(&self, rows: &[&Vec<u128>]) -> Plan {
        let mut plan = Plan::new();
        plan.map = vec![Vec::new(); rows.len()];
        let per_block = mncore_sim::machine::PES; // MABs * 4 cycles = PES rows per block
        for (ci, chunk) in rows.chunks(per_block).enumerate() {
            let ra = chunk[0][0] != 0;
            let bi = plan.blocks.len();
            let mut block = Block { insn: self.insn(ra, false, 0), uses: [true, false, false], items: Vec::new() };
            for (k, row) in chunk.iter().enumerate() {
                let (mab, cycle) = (k / 4, k % 4);
                for p in 0..4 {
                    let x = bus(row[1 + 2 * p] as u64, row[2 + 2 * p] as u64);
                    plan.map[ci * per_block + k].push((bi, block.items.len(), 0));
                    block.items.push(Item { pe: 4 * mab + p, cycle, bus: [x, 0, 0] });
                }
            }
            plan.fields.push(self.expect_fields(ra, false));
            plan.blocks.push(block);
        }
        plan
    }
}

impl Spec for AluSpec {
    fn unit(&self) -> &'static str {
        self.unit
    }

    fn stem(&self) -> String {
        format!("{}{}", self.opcode().replace('/', ""), if self.r { ".r" } else { "" })
    }

    fn sdm(&self) -> bool {
        let u_ok = !self.unsigned
            || match self.kind {
                Kind::Lane(d) => d.u_sdm,
                _ => false,
            };
        // The SDM defines the `r` input option for ALU inputs that expect half precision.
        let r_ok = !self.r || (self.unit == "fpalu" && self.prec == 'h');
        u_ok && r_ok
    }

    fn disputed(&self) -> Option<String> {
        // The official emulator rounds `r` inputs differently (FORMAT.md, r_round).
        self.r.then(|| "r_round".to_string())
    }

    fn row_disputed(&self, _row: &[u128]) -> bool {
        self.r
    }

    fn template(&self) -> VecFile {
        let mut f = VecFile::default();
        f.set("unit", self.unit);
        f.set("op", self.opcode());
        match self.kind {
            Kind::Imm { .. } => {
                f.set("aluop", self.aluop());
                f.set("is_unsigned", yes(self.is_unsigned()));
                f.set("inputs", 0);
                f.cols_in = vec![col("imm", 8)];
                f.cols_out = vec![col("z_hi", 16), col("z_lo", 16), col("flags", 1)];
                return f;
            }
            _ => {}
        }
        f.set("prec", self.prec);
        f.set("lanebits", lane_bits(self.prec));
        f.set("dmode", if matches!(self.kind, Kind::Zero) { "10" } else { dmode(self.prec) });
        f.set("aluop", self.aluop());
        f.set("is_unsigned", yes(self.is_unsigned()));
        if let Some(s) = self.iselb() {
            f.set("iselb", s);
        }
        if matches!(self.kind, Kind::Zero) {
            f.set("isela", "0101");
        }
        f.set("inputs", self.inputs());
        if let Kind::Bf { n, .. } = self.kind {
            let (_, keep) = self.bf_keep();
            if self.prec == 'h' {
                f.set("bf_n", n);
            }
            f.set("bf_keep", keep);
            f.cols_in = vec![col("ra", 1)];
            for p in 0..4 {
                f.cols_in.push(col(&format!("x{p}_hi"), 16));
                f.cols_in.push(col(&format!("x{p}_lo"), 16));
            }
            f.cols_out = Vec::new();
            for p in 0..4 {
                f.cols_out.push(col(&format!("z{p}_hi"), 16));
                f.cols_out.push(col(&format!("z{p}_lo"), 16));
            }
            for p in 0..4 {
                f.cols_out.push(col(&format!("f{p}"), 1));
            }
            return f;
        }
        f.cols_in = ["ra", "rb"].iter().map(|n| col(n, 1)).collect();
        f.cols_in.extend(["x_hi", "x_lo", "y_hi", "y_lo"].iter().map(|n| col(n, 16)));
        f.cols_out = vec![col("z_hi", 16), col("z_lo", 16), col("flags", 1)];
        f
    }

    fn gen_inputs(&self, n: usize, r: &mut Rng) -> (Vec<Vec<u128>>, usize) {
        // Forms the SDM does not document only need to show they behave the same.
        let n = if self.sdm() { n } else { n / 4 };
        match self.kind {
            Kind::Lane(d) => self.gen_lane(d, n, r),
            Kind::Bf { .. } => self.gen_bf(n, r),
            Kind::Zero => {
                let rows: Vec<Vec<u128>> = (0..16 + n / 8)
                    .map(|_| {
                        let x = r.next_u128();
                        let y = r.next_u128();
                        vec![0, 0, hi(x) as u128, lo(x) as u128, hi(y) as u128, lo(y) as u128]
                    })
                    .collect();
                (rows, 16)
            }
            Kind::Imm { .. } => {
                let mut rows: Vec<Vec<u128>> = IMM_EDGE.iter().map(|&v| vec![v as u128]).collect();
                rows.extend((0..32).map(|k| vec![1u128 << k]));
                let edge = rows.len();
                rows.extend((0..n.min(256)).map(|_| vec![r.bits(32) as u128]));
                (rows, edge)
            }
        }
    }

    fn plan(&self, rows: &[&Vec<u128>]) -> Plan {
        match self.kind {
            Kind::Bf { .. } => self.plan_bf(rows),
            Kind::Imm { .. } => {
                let items = rows
                    .iter()
                    .enumerate()
                    .map(|(i, row)| RowItem {
                        rows: vec![(i, 0)],
                        insn: self.insn(false, false, row[0] as u64),
                        fields: self.expect_fields(false, false),
                        uses: [false; 3],
                        bus: [0; 3],
                        subs: ALL_SUBS,
                    })
                    .collect();
                plan_items(rows.len(), items)
            }
            _ => {
                let n_in = self.inputs();
                let items = rows
                    .iter()
                    .enumerate()
                    .map(|(i, row)| {
                        let (ra, rb) = (row[0] != 0, row[1] != 0);
                        let x = bus(row[2] as u64, row[3] as u64);
                        let y = bus(row[4] as u64, row[5] as u64);
                        RowItem {
                            rows: vec![(i, 0)],
                            insn: self.insn(ra, rb, 0),
                            fields: self.expect_fields(ra, rb),
                            uses: [n_in >= 1, n_in == 2, false],
                            bus: [x, y, 0],
                            subs: ALL_SUBS,
                        }
                    })
                    .collect();
                plan_items(rows.len(), items)
            }
        }
    }

    fn outputs(&self, rows: &[&Vec<u128>], plan: &Plan, outs: &[Vec<ItemOut>]) -> Vec<Vec<u128>> {
        (0..rows.len())
            .map(|i| {
                let got: Vec<ItemOut> = plan.map[i].iter().map(|&(b, it, _)| outs[b][it]).collect();
                let mut v: Vec<u128> = Vec::new();
                for o in &got {
                    v.push(hi(o.z) as u128);
                    v.push(lo(o.z) as u128);
                }
                if matches!(self.kind, Kind::Bf { .. }) {
                    v.extend(got.iter().map(|o| o.flags as u128));
                } else {
                    v.push(got[0].flags as u128);
                }
                v
            })
            .collect()
    }
}
