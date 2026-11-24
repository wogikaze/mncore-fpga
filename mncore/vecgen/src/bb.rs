//! Running single PE instructions on many inputs at once.
//!
//! A [`Block`] is one PE instruction plus the operand values of every (PE, cycle) slot it is
//! evaluated on. The same blocks run on two backends:
//! - [`SimBackend`]: the Rust simulator (`third_party/mncore/viz/core`) used as a black box.
//!   The operands are stored into the simulator's PE memories, the instruction text is parsed
//!   by the simulator's own parser and executed, and the results are read back from memory.
//! - `official::run_jobs`: the same instruction and the same memory contents as a VSM program
//!   (`d set` / instruction / `d get`) for the official assembler and emulator in WSL.
//!
//! Fixed memory layout (per PE, word addresses; each cycle uses 4 words = 2 long words):
//! - operand a (first source):  GRF0 words 0..16, read as `$llr0v`
//! - operand b (second source): GRF1 words 0..16, read as `$lls0v`
//! - operand c (third source):  LM0  words 0..16, read as `$llm0v`
//! - result:                    LM1  words 0..16, written as `$lln0v`, and mask entry `$omr1`

use mncore_sim::machine::{MemRead, MemWrite, PES};
use mncore_sim::run::Sim;
use mncore_sim::vsm::{self, MemKind};

/// Memories of operands a, b, c.
pub const IN_MEMS: [MemKind; 3] = [MemKind::Grf0, MemKind::Grf1, MemKind::Lm0];
/// Debug-statement letters of operands a, b, c (`$lr0`, `$ls0`, `$lm0`).
pub const IN_LETTERS: [char; 3] = ['r', 's', 'm'];
/// Source operand texts of a, b, c without options (2 long word access, 4 cycles).
pub const SRC: [&str; 3] = ["$llr0v", "$lls0v", "$llm0v"];
/// Destinations of every instruction: the result and its mask flags.
pub const DST: &str = "$lln0v $omr1";
pub const OUT_MEM: MemKind = MemKind::Lm1;

/// One evaluation slot: PE index (0..4096, chip order), cycle (0..4) and the 2-long-word
/// buses of the operands. Bit 127 of a bus is the MSB of the first word.
#[derive(Clone, Debug)]
pub struct Item {
    pub pe: usize,
    pub cycle: usize,
    pub bus: [u128; 3],
}

#[derive(Clone, Debug)]
pub struct Block {
    pub insn: String,
    /// Which of a, b, c the instruction reads (only those are stored).
    pub uses: [bool; 3],
    pub items: Vec<Item>,
}

/// Result of one slot: the 2 long words written to LM1 and the 4 mask flags of the cycle
/// (bit 3 = flag of the MSB element).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ItemOut {
    pub z: u128,
    pub flags: u8,
}

pub fn bus_words(b: u128) -> [u32; 4] {
    [(b >> 96) as u32, (b >> 64) as u32, (b >> 32) as u32, b as u32]
}

pub fn words_bus(w: [u32; 4]) -> u128 {
    ((w[0] as u128) << 96) | ((w[1] as u128) << 64) | ((w[2] as u128) << 32) | w[3] as u128
}

pub fn hi(b: u128) -> u64 {
    (b >> 64) as u64
}

pub fn lo(b: u128) -> u64 {
    b as u64
}

pub fn bus(hi: u64, lo: u64) -> u128 {
    ((hi as u128) << 64) | lo as u128
}

/// Slot allocator: the k-th slot among the PEs whose position in the MAB is in `subs`.
pub fn slot(k: usize, subs: &[usize]) -> (usize, usize) {
    let per_mab = 4 * subs.len();
    let mab = k / per_mab;
    let r = k % per_mab;
    let pe = 4 * mab + subs[r / 4];
    assert!(pe < PES, "too many slots in one block");
    (pe, r % 4)
}

/// Maximum number of slots in one block for PEs restricted to `subs`.
pub fn capacity(subs: &[usize]) -> usize {
    PES / 4 * subs.len() * 4
}

pub struct SimBackend {
    sim: Sim,
}

impl SimBackend {
    pub fn new() -> SimBackend {
        SimBackend { sim: Sim::new() }
    }

    /// The simulator itself, for units with another memory layout (L1BM / L2BM).
    pub fn sim_mut(&mut self) -> &mut Sim {
        &mut self.sim
    }

    pub fn run_block(&mut self, b: &Block) -> Result<Vec<ItemOut>, String> {
        let mut seen = std::collections::HashSet::new();
        for it in &b.items {
            if !seen.insert((it.pe, it.cycle)) {
                return Err(format!("slot (pe {}, cycle {}) used twice in `{}`", it.pe, it.cycle, b.insn));
            }
            for k in 0..3 {
                if b.uses[k] {
                    for (i, w) in bus_words(it.bus[k]).iter().enumerate() {
                        self.sim.m.mem.poke(IN_MEMS[k], it.pe, 4 * it.cycle + i, *w);
                    }
                }
            }
            // Poison the result slot, so that a result that is not written cannot go unnoticed.
            for i in 0..4 {
                self.sim.m.mem.poke(OUT_MEM, it.pe, 4 * it.cycle + i, 0xdead_beef);
            }
        }
        let lines = vsm::parse(&b.insn).map_err(|e| format!("`{}`: {e}", b.insn))?;
        for (_, line) in &lines {
            self.sim.exec(line).map_err(|e| format!("`{}`: {}", b.insn, e.message()))?;
        }
        Ok(b.items
            .iter()
            .map(|it| {
                let w = [0, 1, 2, 3].map(|i| self.sim.m.mem.peek(OUT_MEM, it.pe, 4 * it.cycle + i));
                let flags = ((self.sim.m.pes[it.pe].mask[1] >> (4 * it.cycle)) & 0xf) as u8;
                ItemOut { z: words_bus(w), flags }
            })
            .collect())
    }

    pub fn run(&mut self, blocks: &[Block]) -> Result<Vec<Vec<ItemOut>>, String> {
        blocks.iter().map(|b| self.run_block(b)).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iadd_two_long_words() {
        // Same values as the emulator probe in the WP03 report: the LSB long word of the
        // result is the LSB long word of x.
        let mut sb = SimBackend::new();
        let x = bus(0x0000_0001_0000_0002, 0xffff_ffff_ffff_ffff);
        let y = bus(0x0000_0003_0000_0004, 0);
        let b = Block {
            insn: format!("iadd {} {} {DST}", SRC[0], SRC[1]),
            uses: [true, true, false],
            items: vec![Item { pe: 5, cycle: 2, bus: [x, y, 0] }],
        };
        let out = sb.run_block(&b).unwrap();
        assert_eq!(out[0].z, bus(0x0000_0004_0000_0006, 0xffff_ffff_ffff_ffff));
        assert_eq!(out[0].flags, 0xf);
    }

    #[test]
    fn slots() {
        assert_eq!(slot(0, &[0, 1, 2, 3]), (0, 0));
        assert_eq!(slot(5, &[0, 1, 2, 3]), (1, 1));
        assert_eq!(slot(5, &[2, 3]), (3, 1));
        assert_eq!(slot(8, &[2, 3]), (6, 0));
    }
}
