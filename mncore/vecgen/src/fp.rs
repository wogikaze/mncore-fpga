//! Basic floating-point functions, one element per row (unit `fp`, WP12 `mn_fp_fma`).
//!
//! Every row is `z = round_out(a * b + c)` as computed by the MAU (SDM 4.3): fma, mul (c = +0),
//! add (b = 1.0) and passa (b = 1.0, c = +0), for d (a, b, c double), f (single) and h (a, b
//! half, c single), with the result in the base or the rounded (`r`) output format. The rows
//! are evaluated by the vector instructions of the MAU (`fvfma`, `dvfmau`, `hvadd`, ...) with
//! the elements packed into the lanes of the operand buses.
//!
//! `cvt_f2h` is the single to half rounding of the ALU `r` input option, evaluated by
//! `hpassa $llr0vr`.

use mncore_sim::float::{self, Fmt, Val, HALF, SINGLE};

use crate::bb::{ItemOut, DST, SRC};
use crate::mau::{formats, lanes, pack_bus, unpack_bus, Kind, KINDS};
use crate::rng::Rng;
use crate::spec::{fields, plan_items, yes, Plan, RowItem, Spec, ALL_SUBS};
use crate::values::*;
use crate::vecfile::{col, VecFile};

pub enum FpSpec {
    Mau { prec: char, kind: Kind, round: bool },
    CvtF2h,
}

pub fn all() -> Vec<FpSpec> {
    let mut v = Vec::new();
    for prec in ['d', 'f', 'h'] {
        for kind in KINDS {
            for round in [false, true] {
                v.push(FpSpec::Mau { prec, kind, round });
            }
        }
    }
    v.push(FpSpec::CvtF2h);
    v
}

pub fn specs() -> Vec<Box<dyn Spec>> {
    all().into_iter().map(|s| Box::new(s) as Box<dyn Spec>).collect()
}

fn digits(f: Fmt) -> usize {
    (f.width() / 4) as usize
}

fn emax_unb(f: Fmt) -> i64 {
    f.exp_max() as i64 - 1 - f.bias() as i64
}

fn emin_unb(f: Fmt) -> i64 {
    1 - f.bias() as i64
}

/// A normal value of `f` with unbiased exponent `e` clamped into range.
fn at(f: Fmt, neg: bool, e: i64, m: u64) -> u64 {
    let e = e.clamp(emin_unb(f), emax_unb(f));
    fnormal(f, neg, e, m).unwrap()
}

struct Ctx {
    fa: Fmt,
    fc: Fmt,
    fo: Fmt,
    kind: Kind,
}

impl Ctx {
    fn one(&self) -> u64 {
        one(self.fa)
    }

    /// The effective operands for the instruction kind.
    fn eff(&self, a: u64, b: u64, c: u64) -> (u64, u64, u64) {
        match self.kind {
            Kind::Fma => (a, b, c),
            Kind::Mul => (a, b, 0),
            Kind::Add => (a, self.one(), c),
            Kind::Passa => (a, self.one(), 0),
        }
    }

    /// Product of a and b rounded to the format of c.
    fn product_c(&self, a: u64, b: u64) -> u64 {
        float::vfma(self.fa, self.fc, float::decode(self.fa, a), float::decode(self.fa, b), Val::Zero { neg: false })
    }

    /// A value of fa on the grid of fo (its mantissa bits below fo's are zero).
    fn on_out_grid(&self, v: u64) -> u64 {
        if self.fo.man_bits >= self.fa.man_bits {
            return v;
        }
        let drop = self.fa.man_bits - self.fo.man_bits;
        v >> drop << drop
    }

    fn edge(&self, r: &mut Rng) -> Vec<(u64, u64, u64)> {
        let (fa, fc, fo) = (self.fa, self.fc, self.fo);
        let mo = fo.man_bits as i64;
        let mut v: Vec<(u64, u64, u64)> = Vec::new();
        let mut push = |a: u64, b: u64, c: u64| v.push((a, b, c));
        let sa = float_small(fa);
        let sc = float_small(fc);
        let full_a = float_specials(fa);
        let full_c = float_specials(fc);
        let neg = |r: &mut Rng| r.chance(1, 2);
        let ord = |r: &mut Rng, f: Fmt| at(f, r.chance(1, 2), r.range(-12, 12), r.bits(f.man_bits));

        // 1. Special values crossed.
        match self.kind {
            Kind::Fma => {
                for &a in &sa {
                    for &b in &sa {
                        for &c in &sc {
                            push(a, b, c);
                        }
                    }
                }
            }
            Kind::Mul => {
                for &a in &full_a {
                    for &b in &full_a {
                        push(a, b, 0);
                    }
                }
            }
            Kind::Add => {
                for &a in &full_a {
                    for &c in &full_c {
                        push(a, 0, c);
                    }
                }
            }
            Kind::Passa => {
                for &a in &full_a {
                    push(a, 0, 0);
                }
            }
        }

        // 2. Cancellation: c close to -(a * b), also with the low mantissa bits whose partial
        //    products single and double drop (SDM 4.3).
        if matches!(self.kind, Kind::Fma | Kind::Add) {
            for i in 0..240 {
                let a = ord(r, fa);
                let b = if self.kind == Kind::Add { self.one() } else { ord(r, fa) };
                let (a, b) = if i % 2 == 1 && fa.mul_full_bits.is_some() {
                    let low = (1u64 << (fa.man_bits - fa.mul_full_bits.unwrap())) - 1;
                    (a | (r.next_u64() & low) | 1, b | (r.next_u64() & low) | 1)
                } else {
                    (a, b)
                };
                let p = self.product_c(a, b);
                let c = (p ^ sign_bit(fc)).wrapping_add(r.below(7)).wrapping_sub(3) & mask(fc.width());
                push(a, b, c);
            }
        }
        // The SDM 4.3 example: (2^20 + 1)^2 - 2^40.
        if fa == SINGLE && self.kind == Kind::Fma {
            push(0x4980_0008, 0x4980_0008, 0xd380_0000);
        }

        // 3. Ties and near ties of the final rounding.
        let half_ulp = |e: i64| e - mo - 1; // exponent of half an ulp of fo at exponent e
        for _ in 0..160 {
            let e = r.range(-10, 10);
            let a = self.on_out_grid(at(fa, neg(r), e, r.bits(fa.man_bits)));
            match self.kind {
                Kind::Add | Kind::Fma => {
                    // b = 1 (add) or a power of two (fma): a * b is exact and on the grid of fo.
                    let k = if self.kind == Kind::Fma { r.range(-3, 3) } else { 0 };
                    let b = at(fa, false, k, 0);
                    let mc = fc.man_bits;
                    let cm = match r.below(4) {
                        0 => 0,                         // exactly half an ulp
                        1 => 1u64 << (mc - r.range(1, 8) as u32), // a bit above
                        2 => (1u64 << mc) - 1,          // just below (as 2^(h-1) * 1.11..1)
                        _ => 1,                         // the smallest amount above
                    };
                    let he = half_ulp(e + k) - if cm == (1u64 << mc) - 1 { 1 } else { 0 };
                    if let Some(c) = fnormal(fc, neg(r), he, cm) {
                        push(a, b, c);
                    }
                }
                Kind::Mul => {
                    // Products of short mantissas land exactly on or near rounding points.
                    let ma = r.bits(fa.man_bits.min(mo as u32 / 2 + 2)) << (fa.man_bits - fa.man_bits.min(mo as u32 / 2 + 2));
                    let mb = r.bits(fa.man_bits.min(mo as u32 / 2 + 2)) << (fa.man_bits - fa.man_bits.min(mo as u32 / 2 + 2));
                    push(at(fa, neg(r), r.range(-6, 6), ma), at(fa, neg(r), r.range(-6, 6), mb), 0);
                }
                Kind::Passa => {
                    if fo.man_bits < fa.man_bits {
                        let drop = fa.man_bits - fo.man_bits;
                        let tie = 1u64 << (drop - 1);
                        let low = r.pick(&[tie, tie, tie - 1, tie + 1, (1u64 << drop) - 1, 1]);
                        push(a | low, 0, 0);
                    } else {
                        push(a, 0, 0);
                    }
                }
            }
        }

        // 4. Overflow of the output format: values around its largest finite number.
        let omax = emax_unb(fo);
        let omm = man_mask(fo) << (fa.man_bits.saturating_sub(fo.man_bits));
        for s in [false, true] {
            for &(da, dm) in &[(0i64, 0u64), (0, 1), (1, 0), (-1, 0)] {
                // a = largest of fo (in fa), shifted by da binades; mantissa varied by dm.
                let ma = (omm.wrapping_sub(dm)) & man_mask(fa);
                if let Some(a) = fnormal(fa, s, omax + da, ma) {
                    match self.kind {
                        Kind::Passa => push(a, 0, 0),
                        Kind::Mul => {
                            for b in [self.one(), at(fa, false, 0, 1), at(fa, false, 1, 0), at(fa, false, -1, man_mask(fa))] {
                                push(a, b, 0);
                            }
                        }
                        Kind::Add | Kind::Fma => {
                            let b = self.one();
                            for (he, cm) in [(omax - mo - 1, 0u64), (omax - mo - 2, man_mask(fc)), (omax - mo - 1, 1), (omax, 0)] {
                                if let Some(c) = fnormal(fc, s, he, cm) {
                                    push(a, b, c);
                                }
                            }
                            push(a, b, 0);
                        }
                    }
                }
                // c alone near the largest value of fo, with a tiny or zero product.
                if matches!(self.kind, Kind::Add | Kind::Fma) {
                    if let Some(c) = fnormal(fc, s, omax + da, omm.wrapping_sub(dm) & man_mask(fc)) {
                        push(0, self.one(), c);
                        push(at(fa, s, emin_unb(fa), 0), self.one(), c);
                    }
                }
            }
            // Products that overflow: two large factors.
            if matches!(self.kind, Kind::Mul | Kind::Fma) {
                for _ in 0..8 {
                    let e1 = r.range(omax / 2 - 2, omax / 2 + 2);
                    let a = at(fa, s, e1, r.bits(fa.man_bits));
                    let b = at(fa, false, omax - e1 + r.range(-1, 1), r.bits(fa.man_bits));
                    push(a, b, if self.kind == Kind::Fma { r.pick(&sc) } else { 0 });
                }
            }
        }

        // 5. Underflow of the output format: results around its smallest normal number.
        let omin = emin_unb(fo);
        for _ in 0..120 {
            let t = omin + r.range(-2, 1);
            let mant = |r: &mut Rng, f: Fmt| if r.chance(1, 3) { man_mask(f) } else { r.bits(f.man_bits) };
            match self.kind {
                Kind::Mul | Kind::Fma => {
                    // Split the exponent t between a and b, both in the range of fa.
                    let (lo_e, hi_e) = ((t - emax_unb(fa)).max(emin_unb(fa)), emax_unb(fa).min(t - emin_unb(fa)));
                    if lo_e > hi_e {
                        continue;
                    }
                    let ea = r.range(lo_e, hi_e);
                    let (Some(a), Some(b)) = (fnormal(fa, neg(r), ea, mant(r, fa)), fnormal(fa, neg(r), t - ea, mant(r, fa))) else {
                        continue;
                    };
                    let c = if self.kind == Kind::Fma && r.chance(1, 2) {
                        fnormal(fc, neg(r), t + r.range(-2, 0), mant(r, fc)).unwrap_or(0)
                    } else {
                        0
                    };
                    push(a, b, c);
                }
                Kind::Add => {
                    let (Some(a), Some(c)) = (fnormal(fa, false, t + r.range(0, 2), mant(r, fa)), fnormal(fc, true, t + r.range(0, 2), mant(r, fc))) else {
                        continue;
                    };
                    push(a, 0, c);
                }
                Kind::Passa => {
                    if let Some(a) = fnormal(fa, neg(r), t, mant(r, fa)) {
                        push(a, 0, 0);
                    }
                }
            }
        }

        // 6. Alignment of c to the adder grid (single and double, SDM 4.3 / NUMERICS.md):
        //    c is truncated with a sticky bit below the smallest kept partial product and
        //    ignored when its leading bit is two or more places below it.
        if let (Some(full), Kind::Fma | Kind::Add) = (fa.mul_full_bits, self.kind) {
            let k = (full + fa.man_bits) as i64;
            for d in (k - 6)..=(k + 4) {
                for _ in 0..12 {
                    let ua = r.range(-4, 4);
                    let ub = if self.kind == Kind::Add { 0 } else { r.range(-4, 4) };
                    let a = at(fa, neg(r), ua, r.bits(fa.man_bits));
                    let b = if self.kind == Kind::Add { self.one() } else { at(fa, false, ub, r.bits(fa.man_bits)) };
                    let cm = match r.below(3) {
                        0 => r.bits(fc.man_bits) | 1,
                        1 => man_mask(fc),
                        _ => 1u64 << (fc.man_bits - 1),
                    };
                    if let Some(c) = fnormal(fc, neg(r), ua + ub - d, cm) {
                        push(a, b, c);
                    }
                }
            }
        }

        v.into_iter().map(|(a, b, c)| self.eff(a, b, c)).collect()
    }

    fn random(&self, r: &mut Rng) -> (u64, u64, u64) {
        let a = float_lane(r, self.fa);
        let b = float_lane(r, self.fa);
        let mut c = float_lane(r, self.fc);
        if self.kind == Kind::Fma && r.chance(1, 4) {
            let p = self.product_c(a, b);
            c = (p ^ sign_bit(self.fc)).wrapping_add(r.below(5)).wrapping_sub(2) & mask(self.fc.width());
        }
        self.eff(a, b, c)
    }
}

impl FpSpec {
    fn ctx(&self) -> Ctx {
        match *self {
            FpSpec::Mau { prec, kind, round } => {
                let (fa, fc, fo) = formats(prec, round);
                Ctx { fa, fc, fo, kind }
            }
            FpSpec::CvtF2h => Ctx { fa: SINGLE, fc: SINGLE, fo: HALF, kind: Kind::Passa },
        }
    }

    fn insn(&self) -> String {
        match *self {
            FpSpec::Mau { prec, kind, round } => {
                let side = if prec == 'd' && matches!(kind, Kind::Fma | Kind::Mul) { "u" } else { "" };
                let op = format!("{prec}v{}{side}{}", kind.name(), if round { "r" } else { "" });
                let srcs: Vec<&str> = (0..3).filter(|&k| kind.uses()[k]).map(|k| SRC[k]).collect();
                format!("{op} {} {DST}", srcs.join(" "))
            }
            FpSpec::CvtF2h => format!("hpassa {}r {DST}", SRC[0]),
        }
    }

    fn expect_fields(&self) -> Vec<(String, String)> {
        match *self {
            FpSpec::Mau { prec, kind, round } => {
                let (pa, zc) = kind.passa_zeroc();
                fields(&[
                    ("pe.mauc.dmode", match prec {
                        'd' => "00",
                        'f' => "01",
                        _ => "10",
                    }),
                    ("pe.mauc.enfma", "1"),
                    ("pe.mauc.round_out", yes(round)),
                    ("pe.mauc.passa", yes(pa)),
                    ("pe.mauc.zeroc", yes(zc)),
                    ("pe.mauc.mdw/side", "0"),
                ])
            }
            FpSpec::CvtF2h => fields(&[("pe.aluc.aluop", "01010"), ("pe.aluc.dmode", "10"), ("pe.aluc.rounda", "1")]),
        }
    }

    /// Elements per evaluated slot and the PE positions that compute them.
    fn layout(&self) -> (usize, &'static [usize]) {
        match *self {
            // dvfmau / dvmulu multiply only in PE 0 and 1 of each MAB.
            FpSpec::Mau { prec: 'd', kind: Kind::Fma | Kind::Mul, .. } => (1, &[0, 1]),
            FpSpec::Mau { prec, .. } => (lanes(prec), ALL_SUBS),
            FpSpec::CvtF2h => (4, ALL_SUBS),
        }
    }
}

impl Spec for FpSpec {
    fn unit(&self) -> &'static str {
        "fp"
    }

    fn stem(&self) -> String {
        match *self {
            FpSpec::Mau { prec, kind, round } => format!("{}_{prec}{}", kind.name(), if round { "r" } else { "" }),
            FpSpec::CvtF2h => "cvt_f2h".into(),
        }
    }

    fn sdm(&self) -> bool {
        !matches!(*self, FpSpec::Mau { prec: 'f', round: true, .. })
    }

    fn disputed(&self) -> Option<String> {
        match *self {
            FpSpec::CvtF2h => Some("r_round".into()),
            FpSpec::Mau { round: true, kind: Kind::Fma | Kind::Add, .. } => Some("round_twice".into()),
            _ => None,
        }
    }

    fn row_disputed(&self, row: &[u128]) -> bool {
        match *self {
            FpSpec::CvtF2h => true,
            // round_twice can only change a result whose value is within a few bits below the
            // base output precision of a tie of the reduced precision. Rows whose result at
            // the base precision is within one ulp of such a tie are counted as affected.
            FpSpec::Mau { prec, round: true, kind: Kind::Fma | Kind::Add } => {
                let (fa, fc, fbase) = formats(prec, false);
                let (_, _, fred) = formats(prec, true);
                let zb = float::vfma(
                    fa,
                    fbase,
                    float::decode(fa, row[0] as u64),
                    float::decode(fa, row[1] as u64),
                    float::decode(fc, row[2] as u64),
                );
                let drop = fbase.man_bits - fred.man_bits;
                let low = (zb & ((1u64 << drop) - 1)) as i64;
                (low - (1i64 << (drop - 1))).abs() <= 1
            }
            _ => false,
        }
    }

    fn template(&self) -> VecFile {
        let c = self.ctx();
        let mut f = VecFile::default();
        f.set("unit", "fp");
        f.set("op", self.stem());
        f.set("insn", self.insn().split_whitespace().next().unwrap());
        f.set("fmt_ab", c.fa.width());
        f.set("fmt_c", c.fc.width());
        f.set("fmt_z", c.fo.width());
        if let FpSpec::CvtF2h = self {
            f.cols_in = vec![col("a", digits(c.fa))];
        } else {
            f.set("kind", c.kind.name());
            f.cols_in = vec![col("a", digits(c.fa)), col("b", digits(c.fa)), col("c", digits(c.fc))];
        }
        f.cols_out = vec![col("z", digits(c.fo))];
        f
    }

    fn gen_inputs(&self, n: usize, r: &mut Rng) -> (Vec<Vec<u128>>, usize) {
        if let FpSpec::CvtF2h = self {
            let mut rows: Vec<Vec<u128>> = f2h_specials().into_iter().map(|a| vec![a as u128]).collect();
            for _ in 0..400 {
                // ties and near ties at every half exponent
                let e = r.range(-33, 33);
                let m = (r.bits(9) << 14) | r.pick(&[1u64 << 13, (1 << 13) - 1, (1 << 13) + 1, 0x3fff, 0]);
                rows.push(vec![at(SINGLE, r.chance(1, 2), e, m) as u128]);
            }
            let edge = rows.len();
            rows.extend((0..n).map(|_| vec![f2h_lane(r) as u128]));
            return (rows, edge);
        }
        let c = self.ctx();
        let mut rows: Vec<Vec<u128>> =
            c.edge(r).into_iter().map(|(a, b, cc)| vec![a as u128, b as u128, cc as u128]).collect();
        let edge = rows.len();
        rows.extend((0..n).map(|_| {
            let (a, b, cc) = c.random(r);
            vec![a as u128, b as u128, cc as u128]
        }));
        (rows, edge)
    }

    fn plan(&self, rows: &[&Vec<u128>]) -> Plan {
        let c = self.ctx();
        let (per, subs) = self.layout();
        let uses = match self {
            FpSpec::Mau { kind, .. } => kind.uses(),
            FpSpec::CvtF2h => [true, false, false],
        };
        let (wa, wc) = if let FpSpec::CvtF2h = self { (32, 32) } else { (c.fa.width(), c.fc.width()) };
        let mut items = Vec::new();
        let idx: Vec<usize> = (0..rows.len()).collect();
        for chunk in idx.chunks(per) {
            let col = |k: usize| -> Vec<u64> { chunk.iter().map(|&i| rows[i].get(k).copied().unwrap_or(0) as u64).collect() };
            let a = pack_bus(&col(0), wa, 0);
            let b = pack_bus(&col(1), wa, 0);
            let cc = pack_bus(&col(2), wc, 0);
            items.push(RowItem {
                rows: chunk.iter().enumerate().map(|(l, &i)| (i, l)).collect(),
                insn: self.insn(),
                fields: self.expect_fields(),
                uses,
                bus: [a, b, cc],
                subs,
            });
        }
        plan_items(rows.len(), items)
    }

    fn outputs(&self, rows: &[&Vec<u128>], plan: &Plan, outs: &[Vec<ItemOut>]) -> Vec<Vec<u128>> {
        let c = self.ctx();
        let (per, _) = self.layout();
        let wo = c.fo.width();
        (0..rows.len())
            .map(|i| {
                let (b, it, lane) = plan.map[i][0];
                let z = unpack_bus(outs[b][it].z, wo, per)[lane];
                vec![z as u128]
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bb::SimBackend;
    use crate::spec::generate;

    /// The rows where the official emulator disagreed (round_twice, full check of seed 1)
    /// are caught by the row predicate.
    #[test]
    fn round_twice_rows_are_flagged() {
        let cases: [(char, Kind, [u128; 3]); 4] = [
            ('d', Kind::Fma, [0xbfeac236d8bb51d4, 0x8035c6c33c000000, 0x400a2cabd0000000]),
            ('d', Kind::Fma, [0x4040000000000000, 0x8041800000000000, 0x4008717130000000]),
            ('f', Kind::Add, [0x017fffff, 0x3f800000, 0x43d9a000]),
            ('h', Kind::Add, [0x0400, 0x3e00, 0xc32f6000]),
        ];
        for (prec, kind, row) in cases {
            assert!(FpSpec::Mau { prec, kind, round: true }.row_disputed(&row), "{prec} {kind:?} {row:x?}");
        }
    }

    /// The rows of every fp file agree with `float::vfma` called directly (the instruction
    /// path and the function the simulator uses for it).
    #[test]
    fn instruction_path_matches_vfma() {
        let mut sim = SimBackend::new();
        for s in all() {
            let f = generate(&s, 200, 7, &mut sim).unwrap();
            if let FpSpec::CvtF2h = s {
                for (ins, outs) in &f.rows {
                    let want = float::encode(HALF, float::decode(SINGLE, ins[0] as u64));
                    assert_eq!(outs[0] as u64, want, "cvt_f2h {:x?}", ins);
                }
                continue;
            }
            let c = s.ctx();
            for (ins, outs) in &f.rows {
                let want = float::vfma(
                    c.fa,
                    c.fo,
                    float::decode(c.fa, ins[0] as u64),
                    float::decode(c.fa, ins[1] as u64),
                    float::decode(c.fc, ins[2] as u64),
                );
                assert_eq!(outs[0] as u64, want, "{} {:x?}", s.stem(), ins);
            }
        }
    }
}
