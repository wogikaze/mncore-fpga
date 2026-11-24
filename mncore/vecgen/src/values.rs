//! Input values: special and boundary values, and random values biased toward them.
//!
//! Formats are MN-Core's (SDM 1.3): half = 1/6/9, single = 1/8/23, double = 1/11/52, no
//! subnormals and no NaN. Exponent field 0 is zero and all ones is infinity, whatever the
//! mantissa is ("dirty" zeros and infinities are included on purpose).

use mncore_sim::float::{Fmt, DOUBLE, HALF, SINGLE};

use crate::rng::Rng;

pub fn mask(w: u32) -> u64 {
    if w >= 64 { u64::MAX } else { (1u64 << w) - 1 }
}

pub fn fmt_of(p: char) -> Fmt {
    match p {
        'd' => DOUBLE,
        'h' => HALF,
        _ => SINGLE,
    }
}

/// Packs lanes into a long word, first lane in the MSBs.
pub fn pack_lanes(lanes: &[u64], w: u32) -> u64 {
    let n = 64 / w as usize;
    let mut v: u64 = 0;
    for i in 0..n {
        let x = lanes.get(i).copied().unwrap_or(0) & mask(w);
        v |= x << (64 - w * (i as u32 + 1));
    }
    v
}

#[cfg(test)]
pub fn unpack_lanes(v: u64, w: u32) -> Vec<u64> {
    (0..64 / w).map(|i| (v >> (64 - w * (i + 1))) & mask(w)).collect()
}

// ---- integers ---------------------------------------------------------------------------

/// Integer lane values for width `w`: 0, ±1, the signed and unsigned extremes and their
/// neighbors, shift counts around w and 2w, bit patterns.
pub fn int_specials(w: u32) -> Vec<u64> {
    let m = mask(w);
    let smax = m >> 1;
    let smin = smax + 1;
    let half = 1u64 << (w / 2);
    let w64 = w as u64;
    let mut v = vec![
        0,
        1,
        2,
        3,
        m,
        m - 1,
        smax,
        smax - 1,
        smin,
        smin + 1,
        w64 - 1,
        w64,
        w64 + 1,
        2 * w64 - 1,
        2 * w64,
        2 * w64 + 1,
        0x5555_5555_5555_5555 & m,
        0xaaaa_aaaa_aaaa_aaaa & m,
        half,
        half - 1,
        m ^ (half - 1),
    ];
    let mut seen = std::collections::HashSet::new();
    v.retain(|x| seen.insert(*x));
    v
}

pub fn int_lane(r: &mut Rng, w: u32) -> u64 {
    let m = mask(w);
    match r.below(12) {
        0..=2 => r.pick(&int_specials(w)),
        3 => r.below(2 * w as u64 + 3),
        4 => m - r.below(16),
        5 => 1u64 << r.below(w as u64),
        6 => (m >> 1).wrapping_add(r.below(5)).wrapping_sub(2) & m,
        7 => (m ^ (1u64 << r.below(w as u64))) & m,
        _ => r.bits(w),
    }
}

/// A pair of lanes, sometimes related (equal, off by one, complement, negation).
pub fn int_pair(r: &mut Rng, w: u32) -> (u64, u64) {
    let m = mask(w);
    let x = int_lane(r, w);
    let y = match r.below(10) {
        0 => x,
        1 => x.wrapping_add(1) & m,
        2 => x.wrapping_sub(1) & m,
        3 => !x & m,
        4 => x.wrapping_neg() & m,
        5 => x ^ (1u64 << r.below(w as u64)),
        _ => int_lane(r, w),
    };
    (x, y)
}

/// A shift count for width `w`: small counts, counts around w and 2w, and large ones
/// (only the count modulo 2w matters, SDM 3.6.12.17).
pub fn shift_count(r: &mut Rng, w: u32) -> u64 {
    let w64 = w as u64;
    match r.below(6) {
        0 | 1 => r.below(w64),
        2 => w64 - 2 + r.below(5),
        3 => 2 * w64 - 2 + r.below(5),
        4 => (2 * w64) * (1 + r.below(64)) + r.below(2 * w64),
        _ => r.bits(w),
    }
    .min(mask(w))
}

// ---- floating point ----------------------------------------------------------------------

pub fn man_mask(f: Fmt) -> u64 {
    (1u64 << f.man_bits) - 1
}

pub fn sign_bit(f: Fmt) -> u64 {
    1u64 << (f.width() - 1)
}

/// Raw bits from sign, exponent field and mantissa field.
pub fn fbits(f: Fmt, neg: bool, e: u64, m: u64) -> u64 {
    ((neg as u64) << (f.width() - 1)) | ((e & f.exp_max()) << f.man_bits) | (m & man_mask(f))
}

/// `sig_frac * 2^unb` with `sig_frac` = 1.mantissa, if the exponent is a normal one.
pub fn fnormal(f: Fmt, neg: bool, unb: i64, m: u64) -> Option<u64> {
    let e = unb + f.bias() as i64;
    if e >= 1 && e < f.exp_max() as i64 { Some(fbits(f, neg, e as u64, m)) } else { None }
}

pub fn one(f: Fmt) -> u64 {
    fbits(f, false, f.bias() as u64, 0)
}

/// Special values of a format: zeros (also with a nonzero mantissa), infinities (also with a
/// nonzero mantissa), the largest and smallest normal numbers, 1, 1 + ulp, 2 - ulp, 0.5,
/// 1.5, 2; with both signs.
pub fn float_specials(f: Fmt) -> Vec<u64> {
    let mm = man_mask(f);
    let emax = f.exp_max();
    let b = f.bias() as u64;
    let pos = [
        fbits(f, false, 0, 0),
        fbits(f, false, 0, 1),
        fbits(f, false, 0, mm),
        fbits(f, false, emax, 0),
        fbits(f, false, emax, 1),
        fbits(f, false, emax, mm),
        fbits(f, false, emax - 1, mm),
        fbits(f, false, emax - 1, 0),
        fbits(f, false, 1, 0),
        fbits(f, false, 1, mm),
        fbits(f, false, 2, 1),
        fbits(f, false, b, 0),
        fbits(f, false, b, 1),
        fbits(f, false, b, mm),
        fbits(f, false, b - 1, mm),
        fbits(f, false, b, 1 << (f.man_bits - 1)),
        fbits(f, false, b + 1, 0),
        fbits(f, false, b - 1, 0),
    ];
    let mut v: Vec<u64> = pos.to_vec();
    v.extend(pos.iter().map(|x| x | sign_bit(f)));
    v
}

/// A shorter list for cross products of two or three operands.
pub fn float_small(f: Fmt) -> Vec<u64> {
    let mm = man_mask(f);
    let emax = f.exp_max();
    let b = f.bias() as u64;
    vec![
        fbits(f, false, 0, 0),
        fbits(f, true, 0, 0),
        fbits(f, false, 0, mm),
        fbits(f, false, emax, 0),
        fbits(f, true, emax, 0),
        fbits(f, false, emax, 1),
        fbits(f, false, emax - 1, mm),
        fbits(f, true, emax - 1, mm),
        fbits(f, false, 1, 0),
        fbits(f, true, 1, 0),
        fbits(f, false, b, 0),
        fbits(f, true, b, 1),
    ]
}

fn random_mantissa(r: &mut Rng, f: Fmt) -> u64 {
    let mm = man_mask(f);
    let m = r.next_u64() & mm;
    let short = f.man_bits.min(6);
    match r.below(8) {
        0 => mm,
        1 => m & !((1u64 << (f.man_bits - short)) - 1),
        2 => m | 1,
        3 => 0,
        4 => m & !((1u64 << (f.man_bits / 2)) - 1),
        _ => m,
    }
}

/// A random value biased toward the cases where rounding and range rules matter.
pub fn float_lane(r: &mut Rng, f: Fmt) -> u64 {
    let emax = f.exp_max();
    let b = f.bias() as u64;
    let neg = r.chance(1, 2);
    let e = match r.below(20) {
        0 => 0,
        1 => emax,
        2 | 3 => 1 + r.below(4),
        4 | 5 => emax - 1 - r.below(4),
        6 => return r.pick(&float_specials(f)),
        7 => return r.bits(f.width()),
        8 | 9 => 1 + r.below(emax - 1),
        _ => b - 8 + r.below(17),
    };
    fbits(f, neg, e, random_mantissa(r, f))
}

/// Exponent fields to sweep: all of them for half, and the ends and the middle otherwise.
pub fn exp_sweep(f: Fmt) -> Vec<u64> {
    let emax = f.exp_max();
    if f.exp_bits <= 6 {
        return (0..=emax).collect();
    }
    let b = f.bias() as u64;
    let mut v: Vec<u64> = (0..=6).collect();
    v.extend(b - 3..=b + 3);
    v.extend(emax - 6..=emax);
    v
}

/// Single-precision values that matter when rounding to half precision (the ALU `r` input
/// option and MAU input rounding): the half range limits, ties and near ties at the half
/// mantissa, values out of the half range, zeros and infinities.
pub fn f2h_specials() -> Vec<u64> {
    let s = SINGLE;
    let h = HALF;
    let hb = h.bias() as i64; // 31
    let emax_unb = h.exp_max() as i64 - 1 - hb; // 31: largest half exponent
    let emin_unb = 1 - hb; // -30
    let drop = s.man_bits - h.man_bits; // 14
    let tie = 1u64 << (drop - 1);
    let hm = man_mask(h) << drop; // half mantissa bits in single
    let mut v = vec![
        fbits(s, false, 0, 0),
        fbits(s, true, 0, 0),
        fbits(s, false, 0, 0x7f_ffff),
        fbits(s, false, 255, 0),
        fbits(s, true, 255, 0),
        fbits(s, true, 255, 0x40_0001),
    ];
    for neg in [false, true] {
        let n = |unb: i64, m: u64| fnormal(s, neg, unb, m).unwrap();
        v.extend([
            n(emax_unb, hm),                 // half max, exact
            n(emax_unb, hm | tie),           // half max + half ulp: ties to even -> inf
            n(emax_unb, hm | (tie - 1)),     // just below the tie -> half max
            n(emax_unb, hm | 0x3fff),        // above the tie -> inf
            n(emax_unb + 1, 0),              // 2^32 -> inf
            n(emin_unb, 0),                  // half min normal
            n(emin_unb - 1, 0x7f_ffff),      // rounds up to the min normal
            n(emin_unb - 1, hm | tie),       // tie just below min normal -> min normal
            n(emin_unb - 1, hm | (tie - 1)), // below the tie -> 0
            n(emin_unb - 1, 0),              // half of the min normal -> 0
            n(emin_unb - 2, 0x55_5555),      // far below -> 0
            n(0, tie),                       // 1 + tie, even -> 1
            n(0, (1 << drop) | tie),         // odd -> rounds up
            n(0, tie + 1),
            n(0, tie - 1),
            n(0, 0x7f_ffff),                 // rounds up to 2
            n(-1, 0),
            n(10, 0x12_3456),
        ]);
    }
    v
}

/// A random single for rounding to half: mostly within or near the half range.
pub fn f2h_lane(r: &mut Rng) -> u64 {
    let s = SINGLE;
    let drop = 14;
    match r.below(10) {
        0 | 1 => r.pick(&f2h_specials()),
        2 => {
            // A tie or a near tie at the half mantissa.
            let m = (r.bits(9) << drop) | r.pick(&[1u64 << (drop - 1), (1 << (drop - 1)) - 1, (1 << (drop - 1)) + 1]);
            fbits(s, r.chance(1, 2), (127 + r.range(-32, 33)) as u64, m)
        }
        3 => float_lane(r, s),
        4 => fbits(s, r.chance(1, 2), (127 + r.range(-34, -28)) as u64, r.bits(23)),
        5 => fbits(s, r.chance(1, 2), (127 + r.range(29, 34)) as u64, r.bits(23)),
        _ => fbits(s, r.chance(1, 2), (127 + r.range(-31, 32)) as u64, r.bits(23)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lanes() {
        assert_eq!(pack_lanes(&[1, 2, 3, 4], 16), 0x0001_0002_0003_0004);
        assert_eq!(unpack_lanes(0x0001_0002_0003_0004, 16), vec![1, 2, 3, 4]);
        assert_eq!(pack_lanes(&[0xdead_beef, 7], 32), 0xdead_beef_0000_0007);
    }

    #[test]
    fn specials() {
        assert_eq!(one(HALF), 0x3e00);
        assert_eq!(one(SINGLE), 0x3f80_0000);
        assert!(float_specials(DOUBLE).contains(&0x7fef_ffff_ffff_ffff));
        assert!(int_specials(16).contains(&0x8000));
        assert_eq!(fnormal(HALF, false, 0, 0), Some(0x3e00));
        assert_eq!(fnormal(HALF, false, 32, 0), None);
    }
}
