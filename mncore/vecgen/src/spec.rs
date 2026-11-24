//! What every vector file definition provides, and the generic generate/check drivers.

use crate::bb::{capacity, slot, Block, Item, ItemOut, SimBackend};
use crate::rng::Rng;
use crate::vecfile::VecFile;

/// The blocks that evaluate a list of rows, and where each row's results come from.
pub struct Plan {
    pub blocks: Vec<Block>,
    /// For each row: (block, item, lane) of every result it collects, in output order.
    pub map: Vec<Vec<(usize, usize, usize)>>,
    /// For each block: instruction fields the assembler must produce (CSV name, bits).
    pub fields: Vec<Vec<(String, String)>>,
}

impl Plan {
    pub fn new() -> Plan {
        Plan { blocks: Vec::new(), map: Vec::new(), fields: Vec::new() }
    }
}

/// One `.vec` file: an instruction (opcode and fixed options) and how to make its rows.
pub trait Spec {
    fn unit(&self) -> &'static str;
    /// File name without `.vec`.
    fn stem(&self) -> String;
    /// Header and columns, without rows.
    fn template(&self) -> VecFile;
    /// Input columns of the rows: the fixed edge cases first, then `n` random rows.
    /// Returns the rows and the number of edge-case rows.
    fn gen_inputs(&self, n: usize, r: &mut Rng) -> (Vec<Vec<u128>>, usize);
    /// The blocks that evaluate the rows (the same plan runs on the simulator and on the
    /// official emulator).
    fn plan(&self, rows: &[&Vec<u128>]) -> Plan;
    /// Output columns of each row from the results of its items.
    fn outputs(&self, rows: &[&Vec<u128>], plan: &Plan, outs: &[Vec<ItemOut>]) -> Vec<Vec<u128>>;
    /// Whether the SDM documents this form (the assembler accepts every generated form).
    fn sdm(&self) -> bool {
        true
    }
    /// Known disagreements between the simulator and the official emulator that affect rows
    /// of this file (codes in FORMAT.md, joined by `+`). The rows keep the simulator's values.
    fn disputed(&self) -> Option<String> {
        None
    }
    /// Whether a row (input columns) is known to be affected. Disagreements that only show
    /// in rare rows that cannot be told from the inputs (round_twice) do not count here.
    fn row_disputed(&self, _row: &[u128]) -> bool {
        false
    }
}

/// One slot to evaluate: its instruction, operand buses, the PE positions in the MAB it may
/// use, and the (row, lane) pairs whose results it holds.
pub struct RowItem {
    pub rows: Vec<(usize, usize)>,
    pub insn: String,
    pub fields: Vec<(String, String)>,
    pub uses: [bool; 3],
    pub bus: [u128; 3],
    pub subs: &'static [usize],
}

pub const ALL_SUBS: &[usize] = &[0, 1, 2, 3];

/// Builds a plan from items: items with the same instruction share blocks, in the order they
/// come. Each item goes to the next free slot of an allowed PE position (the least used one);
/// a new block starts when none is left.
pub fn plan_items(n_rows: usize, items: Vec<RowItem>) -> Plan {
    let mut plan = Plan::new();
    plan.map = vec![Vec::new(); n_rows];
    // Group by instruction, keeping first-appearance order.
    let mut groups: Vec<(String, Vec<RowItem>)> = Vec::new();
    for it in items {
        match groups.iter_mut().find(|(k, _)| *k == it.insn) {
            Some((_, v)) => v.push(it),
            None => groups.push((it.insn.clone(), vec![it])),
        }
    }
    let per_sub = capacity(&[0]);
    for (insn, its) in groups {
        let mut used = [per_sub; 4]; // forces a new block for the first item
        let mut bi = 0;
        for it in &its {
            let pick = |used: &[usize; 4]| it.subs.iter().copied().filter(|&s| used[s] < per_sub).min_by_key(|&s| used[s]);
            let s = match pick(&used) {
                Some(s) => s,
                None => {
                    bi = plan.blocks.len();
                    plan.blocks.push(Block { insn: insn.clone(), uses: it.uses, items: Vec::new() });
                    plan.fields.push(it.fields.clone());
                    used = [0; 4];
                    pick(&used).expect("an item must allow some PE position")
                }
            };
            let (pe, cycle) = slot(used[s], &[s]);
            used[s] += 1;
            let block = &mut plan.blocks[bi];
            for &(row, lane) in &it.rows {
                plan.map[row].push((bi, block.items.len(), lane));
            }
            block.items.push(Item { pe, cycle, bus: it.bus });
        }
    }
    plan
}

pub fn generate(spec: &dyn Spec, n: usize, seed: u64, sim: &mut SimBackend) -> Result<VecFile, String> {
    let mut r = Rng::for_stream(seed, &format!("{}/{}", spec.unit(), spec.stem()));
    let (ins, edge) = spec.gen_inputs(n, &mut r);
    let refs: Vec<&Vec<u128>> = ins.iter().collect();
    let plan = spec.plan(&refs);
    let outs = sim.run(&plan.blocks)?;
    let out_rows = spec.outputs(&refs, &plan, &outs);
    let mut f = spec.template();
    f.set("sdm", if spec.sdm() { "yes" } else { "no" });
    if let Some(d) = spec.disputed() {
        f.set("disputed", d);
    }
    f.set("seed", seed);
    f.set("edge", edge);
    f.set("rows", ins.len());
    f.rows = ins.into_iter().zip(out_rows).collect();
    Ok(f)
}

/// Rows to check against the official emulator: up to `k` rows, at least half of them from
/// the edge cases when there are enough, the rest spread over the random rows.
pub fn sample_rows(f: &VecFile, k: Option<usize>, salt: &str) -> Vec<usize> {
    let n = f.rows.len();
    let Some(k) = k else { return (0..n).collect() };
    if k >= n {
        return (0..n).collect();
    }
    let edge: usize = f.get("edge").and_then(|v| v.parse().ok()).unwrap_or(0).min(n);
    let mut r = Rng::for_stream(0x5eed, salt);
    let mut pick = |range: std::ops::Range<usize>, m: usize| -> Vec<usize> {
        let mut v: Vec<usize> = range.collect();
        r.shuffle(&mut v);
        v.truncate(m);
        v
    };
    let from_edge = (k / 2).max(k.saturating_sub(n - edge)).min(edge);
    let mut v = pick(0..edge, from_edge);
    v.extend(pick(edge..n, k - from_edge));
    v.sort_unstable();
    v
}

pub fn yes(b: bool) -> &'static str {
    if b { "1" } else { "0" }
}

pub fn fields(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect()
}
