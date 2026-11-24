//! MAU vector instructions (SDM 3.6.9, unit `mau`, WP12 `mn_mau_vec`):
//! fma/mul/add/passa for d (with u/d), f and h, with and without output rounding (`r`).
//!
//! Each row is one (PE, cycle) slot. Its input sign inversion and precision extension /
//! rounding options are columns of the row (they are fields of the instruction: one block per
//! combination). Operand a is read from GRF0, b from GRF1 and c from LM0, all with
//! two-long-word access; the result goes to LM1 and mask entry 1.

use mncore_sim::float::{self, Fmt, Val, DOUBLE, HALF, SINGLE};

use crate::bb::{bus, hi, lo, ItemOut, DST, SRC};
use crate::rng::Rng;
use crate::spec::{fields, plan_items, yes, Plan, RowItem, Spec};
use crate::values::*;
use crate::vecfile::{col, VecFile};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Fma,
    Mul,
    Add,
    Passa,
}

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Kind::Fma => "fma",
            Kind::Mul => "mul",
            Kind::Add => "add",
            Kind::Passa => "passa",
        }
    }
    /// Operands a, b, c read by the instruction.
    pub fn uses(self) -> [bool; 3] {
        match self {
            Kind::Fma => [true, true, true],
            Kind::Mul => [true, true, false],
            Kind::Add => [true, false, true],
            Kind::Passa => [true, false, false],
        }
    }
    /// MAUC passa and zeroc bits (Scrapbox "MAU命令の制御組合せ").
    pub fn passa_zeroc(self) -> (bool, bool) {
        match self {
            Kind::Fma => (false, false),
            Kind::Mul => (false, true),
            Kind::Add => (true, false),
            Kind::Passa => (true, true),
        }
    }
}

pub const KINDS: [Kind; 4] = [Kind::Fma, Kind::Mul, Kind::Add, Kind::Passa];

pub struct MauSpec {
    pub prec: char,
    pub kind: Kind,
    /// `u` or `d` for double fma/mul (multiply in PE 0,1 or PE 2,3 only).
    pub side: Option<char>,
    pub round: bool,
}

pub fn specs() -> Vec<Box<dyn Spec>> {
    let mut v: Vec<Box<dyn Spec>> = Vec::new();
    for prec in ['d', 'f', 'h'] {
        for kind in KINDS {
            let sides: Vec<Option<char>> =
                if prec == 'd' && matches!(kind, Kind::Fma | Kind::Mul) { vec![Some('u'), Some('d')] } else { vec![None] };
            for side in sides {
                for round in [false, true] {
                    v.push(Box::new(MauSpec { prec, kind, side, round }));
                }
            }
        }
    }
    v
}

/// Formats of a/b, c and the result (SDM 3.6.9.1: half accumulates in single).
pub fn formats(prec: char, round: bool) -> (Fmt, Fmt, Fmt) {
    match prec {
        'd' => (DOUBLE, DOUBLE, if round { SINGLE } else { DOUBLE }),
        'f' => (SINGLE, SINGLE, if round { HALF } else { SINGLE }),
        _ => (HALF, SINGLE, if round { HALF } else { SINGLE }),
    }
}

pub fn lanes(prec: char) -> usize {
    match prec {
        'd' => 1,
        'f' => 2,
        _ => 4,
    }
}

fn lower(f: Fmt) -> Fmt {
    if f == DOUBLE { SINGLE } else { HALF }
}

pub const SUB: [&[usize]; 4] = [&[0], &[1], &[2], &[3]];

/// Packs values of `w` bits into a bus from the MSB; the remaining bits come from `fill`.
pub fn pack_bus(vals: &[u64], w: u32, fill: u128) -> u128 {
    let used = w * vals.len() as u32;
    let mut b: u128 = if used >= 128 { 0 } else { fill & ((1u128 << (128 - used)) - 1) };
    for (i, v) in vals.iter().enumerate() {
        b |= ((*v & mask(w)) as u128) << (128 - w * (i as u32 + 1));
    }
    b
}

pub fn unpack_bus(b: u128, w: u32, n: usize) -> Vec<u64> {
    (0..n).map(|i| ((b >> (128 - w * (i as u32 + 1))) as u64) & mask(w)).collect()
}

/// Per-row options: [signa, signb, signc, exta, extb, extc].
type Opts = [bool; 6];

impl MauSpec {
    /// Double and single fma/mul, whose extended a/b disagree with the emulator (ext_mul).
    fn ext_mul(&self) -> bool {
        self.prec != 'h' && matches!(self.kind, Kind::Fma | Kind::Mul)
    }

    pub fn opcode(&self) -> String {
        format!(
            "{}v{}{}{}",
            self.prec,
            self.kind.name(),
            self.side.map(String::from).unwrap_or_default(),
            if self.round { "r" } else { "" }
        )
    }

    /// Raw format of operand k (0 = a, 1 = b, 2 = c) with or without its extension option.
    /// For h, the option of a and b is rounding from single (`r`), stored in exta/extb.
    fn raw_fmt(&self, k: usize, ext: bool) -> Fmt {
        let (fa, fc, _) = formats(self.prec, false);
        let base = if k == 2 { fc } else { fa };
        match (self.prec, k, ext) {
            (_, _, false) => base,
            ('h', 0 | 1, true) => SINGLE,
            _ => lower(base),
        }
    }

    fn option_letter(&self, k: usize) -> &'static str {
        if self.prec == 'h' && k < 2 { "r" } else { "e" }
    }

    /// All option combinations allowed for the operands this instruction reads.
    fn combos(&self) -> Vec<Opts> {
        let uses = self.kind.uses();
        let mut v = Vec::new();
        for bits in 0..64u32 {
            let o: Opts = [0, 1, 2, 3, 4, 5].map(|i| (bits >> i) & 1 == 1);
            if (0..3).any(|k| !uses[k] && (o[k] || o[3 + k])) {
                continue;
            }
            v.push(o);
        }
        v
    }

    fn insn(&self, o: &Opts) -> String {
        let uses = self.kind.uses();
        let mut s = self.opcode();
        for k in 0..3 {
            if uses[k] {
                s += &format!(
                    " {}{}{}",
                    if o[k] { "-" } else { "" },
                    SRC[k],
                    if o[3 + k] { self.option_letter(k) } else { "" }
                );
            }
        }
        s + " " + DST
    }

    fn dmode(&self) -> &'static str {
        match self.prec {
            'd' => "00",
            'f' => "01",
            _ => "10",
        }
    }

    fn expect_fields(&self, o: &Opts) -> Vec<(String, String)> {
        let (pa, zc) = self.kind.passa_zeroc();
        let mut v = fields(&[
            ("pe.mauc.dmode", self.dmode()),
            ("pe.mauc.enfma", "1"),
            ("pe.mauc.mmode", "0"),
            ("pe.mauc.round_out", yes(self.round)),
            ("pe.mauc.mdw/side", yes(self.side == Some('d'))),
            ("pe.mauc.passa", yes(pa)),
            ("pe.mauc.zeroc", yes(zc)),
        ]);
        for (i, n) in ["signa", "signb", "signc", "exta", "extb", "extc"].iter().enumerate() {
            v.push((format!("pe.mauc.{n}"), yes(o[i]).to_string()));
        }
        v
    }

    /// Special lane values of operand k in its raw format.
    fn specials(&self, k: usize, ext: bool) -> Vec<u64> {
        if self.prec == 'h' && k < 2 && ext {
            return f2h_specials();
        }
        float_small(self.raw_fmt(k, ext))
    }

    fn random_lane(&self, k: usize, ext: bool, r: &mut Rng) -> u64 {
        if self.prec == 'h' && k < 2 && ext {
            return f2h_lane(r);
        }
        float_lane(r, self.raw_fmt(k, ext))
    }

    fn row(&self, pe: usize, o: &Opts, lanes_abc: [Vec<u64>; 3], r: &mut Rng) -> Vec<u128> {
        let mut v: Vec<u128> = vec![pe as u128];
        v.extend(o.iter().map(|&b| b as u128));
        for k in 0..3 {
            let f = self.raw_fmt(k, o[3 + k]);
            let b = pack_bus(&lanes_abc[k], f.width(), r.next_u128());
            v.push(hi(b) as u128);
            v.push(lo(b) as u128);
        }
        v
    }
}

impl Spec for MauSpec {
    fn unit(&self) -> &'static str {
        "mau"
    }

    fn stem(&self) -> String {
        self.opcode()
    }

    fn sdm(&self) -> bool {
        // SDM 3.6.9.25 documents output rounding for double and half only.
        !(self.round && self.prec == 'f')
    }

    fn disputed(&self) -> Option<String> {
        let mut v = Vec::new();
        if self.ext_mul() {
            v.push("ext_mul");
        }
        if self.prec == 'f' && self.round {
            v.push("fvr_flags");
        }
        if self.round && matches!(self.kind, Kind::Fma | Kind::Add) {
            v.push("round_twice");
        }
        (!v.is_empty()).then(|| v.join("+"))
    }

    fn row_disputed(&self, row: &[u128]) -> bool {
        // fvr_flags: the flags of every row; ext_mul: rows with exta or extb set.
        (self.prec == 'f' && self.round) || (self.ext_mul() && (row[4] != 0 || row[5] != 0))
    }

    fn template(&self) -> VecFile {
        let (fa, fc, fo) = formats(self.prec, self.round);
        let (pa, zc) = self.kind.passa_zeroc();
        let mut f = VecFile::default();
        f.set("unit", "mau");
        f.set("op", self.opcode());
        f.set("prec", self.prec);
        f.set("kind", self.kind.name());
        f.set("lanes", lanes(self.prec));
        f.set("fmt_ab", fa.width());
        f.set("fmt_c", fc.width());
        f.set("fmt_z", fo.width());
        f.set("dmode", self.dmode());
        f.set("enfma", 1);
        f.set("mmode", 0);
        f.set("round_out", yes(self.round));
        f.set("mdw_side", yes(self.side == Some('d')));
        f.set("passa", yes(pa));
        f.set("zeroc", yes(zc));
        f.set("mul_pes", match self.side {
            Some('u') => "01",
            Some('d') => "23",
            _ => "0123",
        });
        f.cols_in = vec![col("pe", 1)];
        f.cols_in.extend(["signa", "signb", "signc", "exta", "extb", "extc"].iter().map(|n| col(n, 1)));
        f.cols_in.extend(["a_hi", "a_lo", "b_hi", "b_lo", "c_hi", "c_lo"].iter().map(|n| col(n, 16)));
        f.cols_out = vec![col("z_hi", 16), col("z_lo", 16), col("flags", 1)];
        f
    }

    fn gen_inputs(&self, n: usize, r: &mut Rng) -> (Vec<Vec<u128>>, usize) {
        let combos = self.combos();
        let nl = lanes(self.prec);
        let uses = self.kind.uses();
        let mut rows = Vec::new();
        // Edge cases: for every option combination, 48 lane triples taken in turn from the
        // cross product of the special values of a, b and c (the turn continues across
        // combinations, so the whole cross product is covered), in every PE position.
        let per_combo = 48usize;
        let mut t = 0usize;
        for o in &combos {
            let sa = self.specials(0, o[3]);
            let sb = self.specials(1, o[4]);
            let sc = self.specials(2, o[5]);
            let mut lanes_abc: [Vec<u64>; 3] = Default::default();
            for _ in 0..per_combo {
                let (ia, ib, ic) = match (uses[1], uses[2]) {
                    (true, true) => (t % sa.len(), (t / sa.len()) % sb.len(), (t / (sa.len() * sb.len())) % sc.len()),
                    (true, false) => (t % sa.len(), (t / sa.len()) % sb.len(), 0),
                    (false, true) => (t % sa.len(), 0, (t / sa.len()) % sc.len()),
                    _ => (t % sa.len(), 0, 0),
                };
                t += 1;
                lanes_abc[0].push(sa[ia]);
                lanes_abc[1].push(if uses[1] { sb[ib] } else { r.next_u64() });
                lanes_abc[2].push(if uses[2] { sc[ic] } else { r.next_u64() });
                if lanes_abc[0].len() == nl {
                    let pe = (rows.len()) % 4;
                    let l = std::mem::take(&mut lanes_abc);
                    rows.push(self.row(pe, o, l, r));
                }
            }
        }
        let edge = rows.len();
        let (fa, fc, _) = formats(self.prec, false);
        for i in 0..n {
            let o = combos[i % combos.len()];
            let mut l: [Vec<u64>; 3] = Default::default();
            for _ in 0..nl {
                let a = self.random_lane(0, o[3], r);
                let b = self.random_lane(1, o[4], r);
                let mut c = self.random_lane(2, o[5], r);
                // c close to -(a * b): cancellation (only without options, where the raw
                // values are the operand values).
                if self.kind == Kind::Fma && o == [false; 6] && r.chance(1, 3) {
                    let p = float::vfma(fa, fc, float::decode(fa, a), float::decode(fa, b), Val::Zero { neg: false });
                    c = (p ^ sign_bit(fc)).wrapping_add(r.below(5)).wrapping_sub(2) & mask(fc.width());
                }
                l[0].push(a);
                l[1].push(b);
                l[2].push(c);
            }
            rows.push(self.row(r.below(4) as usize, &o, l, r));
        }
        (rows, edge)
    }

    fn plan(&self, rows: &[&Vec<u128>]) -> Plan {
        let items = rows
            .iter()
            .enumerate()
            .map(|(i, row)| {
                let o: Opts = [0, 1, 2, 3, 4, 5].map(|k| row[1 + k] != 0);
                let a = bus(row[7] as u64, row[8] as u64);
                let b = bus(row[9] as u64, row[10] as u64);
                let c = bus(row[11] as u64, row[12] as u64);
                RowItem {
                    rows: vec![(i, 0)],
                    insn: self.insn(&o),
                    fields: self.expect_fields(&o),
                    uses: self.kind.uses(),
                    bus: [a, b, c],
                    subs: SUB[row[0] as usize & 3],
                }
            })
            .collect();
        plan_items(rows.len(), items)
    }

    fn outputs(&self, rows: &[&Vec<u128>], plan: &Plan, outs: &[Vec<ItemOut>]) -> Vec<Vec<u128>> {
        (0..rows.len())
            .map(|i| {
                let (b, it, _) = plan.map[i][0];
                let o = outs[b][it];
                vec![hi(o.z) as u128, lo(o.z) as u128, o.flags as u128]
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opcodes_and_operands() {
        let s = MauSpec { prec: 'd', kind: Kind::Fma, side: Some('u'), round: true };
        assert_eq!(s.opcode(), "dvfmaur");
        assert_eq!(s.insn(&[true, false, true, false, true, false]), "dvfmaur -$llr0v $lls0ve -$llm0v $lln0v $omr1");
        let h = MauSpec { prec: 'h', kind: Kind::Add, side: None, round: false };
        assert_eq!(h.insn(&[false, false, false, true, false, true]), "hvadd $llr0vr $llm0ve $lln0v $omr1");
        assert_eq!(h.combos().len(), 16);
        assert_eq!(pack_bus(&[0x3e00, 0x3e01], 16, 0), 0x3e00_3e01u128 << 96);
    }
}
