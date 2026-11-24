//! The official assembler and emulator as a second backend for [`Block`]s.
//!
//! Each job becomes one VSM program. Every block of the job is written as
//!
//! ```text
//! d set $lr0n0c0b0m0p0 8 <8 long words>     operands a/b/c of each PE (GRF0/GRF1/LM0)
//! <instruction>                             exactly the text the simulator ran
//! nop/3
//! d get $ln0n0c0b0 8                        results of each L1B that holds a slot
//! d get $omr1n0c0b0 1                       mask flags of the same PEs
//! ```
//!
//! The programs are assembled in flat mode and run by `scripts/run_official.sh` in WSL (or
//! directly on Linux). A second program per job holds only the distinct instructions; the
//! assembler's CSV of it gives the instruction fields that the `.vec` headers claim.

use std::collections::HashMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use mncore_sim::machine::PeId;

use crate::bb::{bus_words, words_bus, Block, ItemOut, IN_LETTERS};

pub struct Job {
    pub name: String,
    pub blocks: Vec<Block>,
}

pub struct JobResult {
    /// Results of every block and item, or why the emulator did not produce them.
    pub outs: Result<Vec<Vec<ItemOut>>, String>,
    /// Assembler CSV fields of each distinct instruction text.
    pub fields: Result<HashMap<String, HashMap<String, String>>, String>,
    /// Disagreements between the CSV fields and the flat `j` word (ALUC/MAUC positions).
    pub field_position_errors: Vec<String>,
}

enum GetKind {
    Lm1,
    Omr,
}

struct Get {
    text: String,
    block: usize,
    kind: GetKind,
}

pub fn l1b_loc(l1b: usize) -> String {
    format!("n{}c{}b{}", l1b / 16, (l1b / 8) % 2, l1b % 8)
}

pub fn l2b_loc(l2b: usize) -> String {
    format!("n{}c{}", l2b / 2, l2b % 2)
}

fn build(job: &Job) -> (String, Vec<Get>, Vec<String>) {
    let mut vsm = String::new();
    let mut gets = Vec::new();
    let mut insns: Vec<String> = Vec::new();
    for (bi, b) in job.blocks.iter().enumerate() {
        writeln!(vsm, "# block {bi}").unwrap();
        // Long words of each operand of each PE: 4 cycles x 2 long words.
        let mut per_pe: std::collections::BTreeMap<usize, [[u64; 8]; 3]> = Default::default();
        for it in &b.items {
            let e = per_pe.entry(it.pe).or_insert([[0; 8]; 3]);
            for k in 0..3 {
                let w = bus_words(it.bus[k]);
                e[k][2 * it.cycle] = ((w[0] as u64) << 32) | w[1] as u64;
                e[k][2 * it.cycle + 1] = ((w[2] as u64) << 32) | w[3] as u64;
            }
        }
        for (pe, ops) in &per_pe {
            let name = PeId::from_index(*pe).name();
            for k in 0..3 {
                if !b.uses[k] {
                    continue;
                }
                write!(vsm, "d set $l{}0{} 8 ", IN_LETTERS[k], name).unwrap();
                for v in ops[k] {
                    write!(vsm, "{v:016x}").unwrap();
                }
                vsm.push('\n');
            }
        }
        writeln!(vsm, "{}", b.insn).unwrap();
        vsm += "nop/3\n";
        // Read back each L1B that holds slots: the whole L1B when many of its MABs are used,
        // otherwise only the MABs used (the emulator is slow to print many PEs).
        let mut mabs: Vec<usize> = per_pe.keys().map(|pe| pe / 4).collect();
        mabs.dedup();
        let mut locs: Vec<String> = Vec::new();
        let mut i = 0;
        while i < mabs.len() {
            let l1b = mabs[i] / 16;
            let j = mabs[i..].iter().position(|m| m / 16 != l1b).map_or(mabs.len(), |p| i + p);
            if j - i > 4 {
                locs.push(l1b_loc(l1b));
            } else {
                locs.extend(mabs[i..j].iter().map(|m| format!("{}m{}", l1b_loc(l1b), m % 16)));
            }
            i = j;
        }
        for loc in locs {
            let t = format!("d get $ln0{loc} 8");
            writeln!(vsm, "{t}").unwrap();
            gets.push(Get { text: t, block: bi, kind: GetKind::Lm1 });
            let t = format!("d get $omr1{loc} 1");
            writeln!(vsm, "{t}").unwrap();
            gets.push(Get { text: t, block: bi, kind: GetKind::Omr });
        }
        if !insns.contains(&b.insn) {
            insns.push(b.insn.clone());
        }
    }
    (vsm, gets, insns)
}

pub struct DumpLine {
    pub mem: String,
    /// Location: PE (`n0c0b0m0p0`), L1B (`n0c0b0`) or L2B (`n0c0`).
    pub pe: String,
    pub addr: u32,
    pub value: u64,
    /// The `d get` statement that printed the line.
    pub stmt: String,
}

pub fn parse_dump_lines(dump: &str) -> Result<Vec<DumpLine>, String> {
    let mut out = Vec::new();
    for line in dump.lines() {
        let Some(rest) = line.strip_prefix("DEBUG-") else { continue };
        let bad = || format!("cannot parse dump line `{line}`");
        let (mem, rest) = rest.split_once('(').ok_or_else(bad)?;
        let (loc, rest) = rest.split_once(')').ok_or_else(bad)?;
        let (pe, addr) = loc.split_once(',').ok_or_else(bad)?;
        let addr: u32 = addr.trim().parse().map_err(|_| bad())?;
        let (payload, stmt) = rest.rsplit_once(" #").ok_or_else(bad)?;
        let value = if let Some(m) = payload.find("Mask{") {
            let digits: String = payload[m + 5..].chars().take_while(|c| c.is_ascii_digit()).collect();
            digits.parse::<u64>().map_err(|_| bad())?
        } else if let Some(v) = payload.find("v:0x") {
            let digits: String = payload[v + 4..].chars().take_while(|c| c.is_ascii_hexdigit()).collect();
            u64::from_str_radix(&digits, 16).map_err(|_| bad())?
        } else {
            return Err(bad());
        };
        out.push(DumpLine { mem: mem.to_string(), pe: pe.to_string(), addr, value, stmt: stmt.trim().to_string() });
    }
    Ok(out)
}

fn pe_index(name: &str) -> Option<usize> {
    // n<g>c<l2b>b<l1b>m<mab>p<pe>
    let mut v = [0usize; 5];
    let mut s = name;
    for (i, tag) in ['n', 'c', 'b', 'm', 'p'].iter().enumerate() {
        s = s.strip_prefix(*tag)?;
        let end = s.find(|c: char| !c.is_ascii_digit()).unwrap_or(s.len());
        v[i] = s[..end].parse().ok()?;
        s = &s[end..];
    }
    Some((((v[0] * 2 + v[1]) * 8 + v[2]) * 16 + v[3]) * 4 + v[4])
}

fn parse_outputs(dump: &str, job: &Job, gets: &[Get]) -> Result<Vec<Vec<ItemOut>>, String> {
    let lines = parse_dump_lines(dump)?;
    // Group consecutive lines of the same statement; groups match the `d get`s in order.
    let mut groups: Vec<(String, Vec<&DumpLine>)> = Vec::new();
    for l in &lines {
        match groups.last_mut() {
            Some((s, g)) if *s == l.stmt => g.push(l),
            _ => groups.push((l.stmt.clone(), vec![l])),
        }
    }
    if groups.len() != gets.len() {
        return Err(format!("dump has {} statement groups, expected {}", groups.len(), gets.len()));
    }
    // (block, pe, cycle) -> words / flags
    let mut words: HashMap<(usize, usize, usize), [u32; 4]> = HashMap::new();
    let mut flags: HashMap<(usize, usize, usize), u8> = HashMap::new();
    let mut omr_seen: HashMap<(usize, usize), usize> = HashMap::new();
    for ((stmt, g), get) in groups.iter().zip(gets) {
        if *stmt != get.text {
            return Err(format!("dump statement `{stmt}` where `{}` was expected", get.text));
        }
        for l in g {
            let pe = pe_index(&l.pe).ok_or_else(|| format!("bad PE name {}", l.pe))?;
            match get.kind {
                GetKind::Lm1 => {
                    if l.mem != "LM1" {
                        return Err(format!("unexpected memory {} in `{stmt}`", l.mem));
                    }
                    let long = (l.addr / 2) as usize;
                    let (cycle, half) = (long / 2, long % 2);
                    let e = words.entry((get.block, pe, cycle)).or_insert([0; 4]);
                    e[2 * half] = (l.value >> 32) as u32;
                    e[2 * half + 1] = l.value as u32;
                }
                GetKind::Omr => {
                    if l.mem != "OMR" {
                        return Err(format!("unexpected memory {} in `{stmt}`", l.mem));
                    }
                    let k = omr_seen.entry((get.block, pe)).or_insert(0);
                    flags.insert((get.block, pe, *k % 4), l.value as u8);
                    *k += 1;
                }
            }
        }
    }
    let mut out = Vec::new();
    for (bi, b) in job.blocks.iter().enumerate() {
        let mut v = Vec::new();
        for it in &b.items {
            let w = words
                .get(&(bi, it.pe, it.cycle))
                .ok_or_else(|| format!("no result for block {bi} pe {} cycle {}", it.pe, it.cycle))?;
            let f = flags
                .get(&(bi, it.pe, it.cycle))
                .ok_or_else(|| format!("no flags for block {bi} pe {} cycle {}", it.pe, it.cycle))?;
            v.push(ItemOut { z: words_bus(*w), flags: *f });
        }
        out.push(v);
    }
    Ok(out)
}

/// Parses `assemble3 --print-csv` output: the `i` header and the `i` rows, in order.
fn parse_csv(text: &str) -> Result<Vec<HashMap<String, String>>, String> {
    let mut header: Option<Vec<String>> = None;
    let mut rows = Vec::new();
    for line in text.lines() {
        if !line.starts_with("i,") {
            continue;
        }
        let cells: Vec<String> =
            line.split(',').map(|c| c.trim().trim_start_matches('=').trim_matches('"').to_string()).collect();
        if !line.contains("=\"") {
            header = Some(cells);
            continue;
        }
        let h = header.as_ref().ok_or("CSV row before header")?;
        rows.push(h.iter().cloned().zip(cells).collect());
    }
    Ok(rows)
}

/// The `j` lines of a flat assembly, as bit strings.
fn parse_j(text: &str) -> Vec<String> {
    text.lines().filter_map(|l| l.strip_prefix("j ")).map(|s| s.trim().to_string()).collect()
}

/// Start positions of the ALUC and MAUC fields in the flat `j` word (pos 0 = leftmost bit).
///
/// ALUC (145..161) is in the order of the CSV header. MAUC (116..144) is not: the positions
/// of signa/signc/passa/zeroc/mdw_side/exta/extb/extc/signb were determined from 1,645
/// assembled instructions (every value seen at exactly one position). mmode, mw, ma and readh
/// were always 0 in those, so their positions (119, 121, 122, 131) are inferred.
const J_FIELDS: [(&str, usize); 26] = [
    ("pe.mauc.dmode", 116),
    ("pe.mauc.enfma", 118),
    ("pe.mauc.mmode", 119),
    ("pe.mauc.round_out", 120),
    ("pe.mauc.mw", 121),
    ("pe.mauc.ma", 122),
    ("pe.mauc.signa", 126),
    ("pe.mauc.signc", 127),
    ("pe.mauc.passa", 128),
    ("pe.mauc.zeroc", 129),
    ("pe.mauc.mdw/side", 130),
    ("pe.mauc.readh", 131),
    ("pe.mauc.exta", 132),
    ("pe.mauc.extb", 133),
    ("pe.mauc.extc", 134),
    ("pe.mauc.signb", 135),
    ("pe.mauc.isela", 136),
    ("pe.mauc.iselb", 139),
    ("pe.mauc.iselc", 142),
    ("pe.aluc.dmode", 145),
    ("pe.aluc.aluop", 147),
    ("pe.aluc.is_unsigned", 152),
    ("pe.aluc.rounda", 153),
    ("pe.aluc.roundb", 154),
    ("pe.aluc.isela", 155),
    ("pe.aluc.iselb", 159),
];

fn check_positions(insns: &[String], rows: &[HashMap<String, String>], js: &[String]) -> Vec<String> {
    let mut errs = Vec::new();
    if rows.len() != insns.len() || js.len() != insns.len() {
        errs.push(format!("{} instructions, {} CSV rows, {} j words", insns.len(), rows.len(), js.len()));
        return errs;
    }
    for ((insn, row), j) in insns.iter().zip(rows).zip(js) {
        for (name, start) in J_FIELDS {
            let csv = row.get(name).cloned().unwrap_or_default();
            let bits = j.get(start..start + csv.len()).unwrap_or("");
            if csv != bits {
                errs.push(format!("`{insn}`: {name} = {csv} in the CSV but j[{start}..] = {bits}"));
            }
        }
    }
    errs
}

/// `C:\a\b` -> `/mnt/c/a/b` (for WSL).
pub fn wsl_path(p: &Path) -> String {
    let s = p.to_string_lossy().replace('\\', "/");
    let s = s.strip_prefix("//?/").unwrap_or(&s).to_string();
    let b = s.as_bytes();
    if b.len() >= 2 && b[1] == b':' {
        format!("/mnt/{}{}", (b[0] as char).to_ascii_lowercase(), &s[2..])
    } else {
        s
    }
}

pub fn script_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("scripts").join("run_official.sh")
}

/// Runs the official tools on every VSM file of `dir`.
fn run_script(dir: &Path) -> Result<String, String> {
    let script = script_path();
    let emu = std::env::var("MNCORE_EMU_DIR").ok();
    let out = if cfg!(windows) {
        let distro = std::env::var("VECGEN_WSL_DISTRO").unwrap_or_else(|_| "Ubuntu".into());
        let mut c = Command::new("wsl");
        c.args(["-d", &distro, "--", "bash", &wsl_path(&script), &wsl_path(dir)]);
        if let Some(e) = &emu {
            c.arg(e);
        }
        c.output()
    } else {
        let mut c = Command::new("bash");
        c.arg(&script).arg(dir);
        if let Some(e) = &emu {
            c.arg(e);
        }
        c.output()
    }
    .map_err(|e| format!("cannot start the official tools: {e}"))?;
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    if !out.status.success() {
        return Err(format!(
            "run_official.sh failed: {}\n{}",
            stdout,
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    Ok(stdout)
}

fn read_err(work: &Path, file: &str) -> String {
    std::fs::read_to_string(work.join(file)).unwrap_or_default().lines().take(5).collect::<Vec<_>>().join(" / ")
}

/// A VSM program for the official tools and the distinct instructions whose fields to read.
pub struct RawJob {
    pub name: String,
    pub vsm: String,
    pub insns: Vec<String>,
}

pub struct RawResult {
    /// The debug dump, or why there is none.
    pub dump: Result<String, String>,
    pub fields: Result<HashMap<String, HashMap<String, String>>, String>,
    pub field_position_errors: Vec<String>,
}

/// Writes every job as VSM programs into `work`, runs the official tools once over the
/// directory, and collects the dumps and instruction fields.
pub fn run_raw(work: &Path, jobs: &[RawJob]) -> Result<Vec<RawResult>, String> {
    if work.exists() {
        std::fs::remove_dir_all(work).map_err(|e| format!("{}: {e}", work.display()))?;
    }
    std::fs::create_dir_all(work).map_err(|e| format!("{}: {e}", work.display()))?;
    for job in jobs {
        std::fs::write(work.join(format!("{}.vsm", job.name)), &job.vsm).map_err(|e| e.to_string())?;
        let fields: String = job.insns.iter().map(|i| format!("{i}\n")).collect();
        std::fs::write(work.join(format!("{}.fields.vsm", job.name)), fields).map_err(|e| e.to_string())?;
    }
    let log = run_script(work)?;
    for l in log.lines().filter(|l| !l.starts_with("run_official")) {
        eprintln!("  official: {l}");
    }
    let mut results = Vec::new();
    for job in jobs {
        let name = &job.name;
        let insns = &job.insns;
        let dump = std::fs::read_to_string(work.join(format!("{name}.dmp"))).map_err(|_| {
            format!(
                "no dump; assembler: {} ; emulator: {}",
                read_err(work, &format!("{name}.asm.err")),
                read_err(work, &format!("{name}.emu.err"))
            )
        });
        let mut field_position_errors = Vec::new();
        let fields = match std::fs::read_to_string(work.join(format!("{name}.fields.csv"))) {
            Ok(csv) => parse_csv(&csv).and_then(|rows| {
                let js = std::fs::read_to_string(work.join(format!("{name}.fields.asm")))
                    .map(|t| parse_j(&t))
                    .unwrap_or_default();
                field_position_errors = check_positions(insns, &rows, &js);
                if rows.len() != insns.len() {
                    return Err(format!(
                        "CSV has {} rows for {} instructions ({})",
                        rows.len(),
                        insns.len(),
                        read_err(work, &format!("{name}.fields.csv.err"))
                    ));
                }
                Ok(insns.iter().cloned().zip(rows).collect())
            }),
            Err(_) => Err(format!("no CSV: {}", read_err(work, &format!("{name}.fields.csv.err")))),
        };
        results.push(RawResult { dump, fields, field_position_errors });
    }
    Ok(results)
}

/// Runs PE-instruction blocks on the official tools (see the module comment).
pub fn run_jobs(work: &Path, jobs: &[Job]) -> Result<Vec<JobResult>, String> {
    let mut raws = Vec::new();
    let mut gets_all = Vec::new();
    for job in jobs {
        let (vsm, gets, insns) = build(job);
        raws.push(RawJob { name: job.name.clone(), vsm, insns });
        gets_all.push(gets);
    }
    let res = run_raw(work, &raws)?;
    Ok(res
        .into_iter()
        .zip(jobs.iter().zip(gets_all))
        .map(|(r, (job, gets))| JobResult {
            outs: r.dump.and_then(|d| parse_outputs(&d, job, &gets)),
            fields: r.fields,
            field_position_errors: r.field_position_errors,
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_paths() {
        assert_eq!(pe_index("n0c0b0m0p0"), Some(0));
        assert_eq!(pe_index(&PeId::from_index(3001).name()), Some(3001));
        assert_eq!(wsl_path(Path::new(r"C:\wgkz\x y\z.sh")), "/mnt/c/wgkz/x y/z.sh");
        assert_eq!(l1b_loc(63), "n3c1b7");
    }

    #[test]
    fn dump_lines() {
        let d = "DEBUG-LM1(n0c0b0m0p0,2):(f:-inf, i:{{0xFFFF,0xFFFF},{0xFFFF,0xFFFF}}, v:0xFFFFFFFFFFFFFFFF) #d get $ln0n0c0b0 8\n\
                 DEBUG-OMR(n0c0b0m0p1,1):Mask{12} #d get $omr1n0c0b0 1\n";
        let l = parse_dump_lines(d).unwrap();
        assert_eq!(l[0].value, u64::MAX);
        assert_eq!(l[0].addr, 2);
        assert_eq!(l[1].value, 12);
        assert_eq!(l[1].stmt, "d get $omr1n0c0b0 1");
    }
}
