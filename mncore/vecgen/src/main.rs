//! vecgen: unit test vectors for the nano20k RTL, from the mncore Rust simulator.
//!
//! ```text
//! vecgen <unit|all> [--n N] [--seed S] [--out DIR] [--only TEXT]
//!     Generate mncore/sim/vectors/<unit>/<op>.vec (edge cases + N random rows per file).
//! vecgen <unit|all> --check-official [--sample K|all] [--in DIR] [--work DIR] [--only TEXT]
//!     Run up to K rows of every file (default 256) as VSM programs on the official
//!     assembler and emulator (WSL) and compare results and instruction fields.
//! vecgen <unit|all> --official-expect [--in DIR] [--out DIR] [--work DIR] [--only TEXT]
//!     Run every row of the files marked `disputed` on the official tools and replace the
//!     expected values of the rows where the emulator differs from the simulator.
//! vecgen fixed [--rows R] [--in DIR] [--out DIR]
//!     Copy R rows (default 50) of every file the SDM documents to mncore/sim/vectors_fixed,
//!     leaving out rows of known disagreements with the official emulator (FORMAT.md).
//! vecgen list <unit|all>
//! ```
//!
//! Units: alu, fpalu, mau, fp, rrn (see FORMAT.md).

mod alu;
mod bb;
mod fp;
mod mau;
mod official;
mod rng;
mod rrn;
mod spec;
mod values;
mod vecfile;

use std::path::PathBuf;
use std::time::Instant;

use spec::{generate, sample_rows, Spec};
use vecfile::VecFile;

const UNITS: [&str; 5] = ["alu", "fpalu", "mau", "fp", "rrn"];

/// Stems and SDM status of the files of a unit.
fn stems(unit: &str) -> Vec<(String, bool)> {
    if unit == "rrn" {
        return rrn::specs().iter().map(|s| (s.stem(), true)).collect();
    }
    specs(unit).iter().map(|s| (s.stem(), s.sdm())).collect()
}

fn specs(unit: &str) -> Vec<Box<dyn Spec>> {
    match unit {
        "alu" => alu::specs("alu"),
        "fpalu" => alu::specs("fpalu"),
        "mau" => mau::specs(),
        "fp" => fp::specs(),
        _ => Vec::new(),
    }
}

fn repo_mncore() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

struct Args {
    cmd: String,
    n: usize,
    seed: u64,
    out: Option<PathBuf>,
    input: Option<PathBuf>,
    work: Option<PathBuf>,
    only: Option<String>,
    check: bool,
    official_expect: bool,
    sample: Option<usize>,
    rows: usize,
}

fn parse_args() -> Result<Args, String> {
    let mut it = std::env::args().skip(1);
    let cmd = it.next().ok_or("usage: vecgen <unit|all|fixed|list> [options] (see src/main.rs)")?;
    let mut a = Args {
        cmd,
        n: 1000,
        seed: 1,
        out: None,
        input: None,
        work: None,
        only: None,
        check: false,
        official_expect: false,
        sample: Some(256),
        rows: 50,
    };
    let mut unit_for_list = None;
    while let Some(o) = it.next() {
        let mut val = |name: &str| it.next().ok_or(format!("{name} needs a value"));
        match o.as_str() {
            "--n" => a.n = val("--n")?.parse().map_err(|_| "bad --n")?,
            "--seed" => a.seed = val("--seed")?.parse().map_err(|_| "bad --seed")?,
            "--out" => a.out = Some(PathBuf::from(val("--out")?)),
            "--in" => a.input = Some(PathBuf::from(val("--in")?)),
            "--work" => a.work = Some(PathBuf::from(val("--work")?)),
            "--only" => a.only = Some(val("--only")?),
            "--check-official" => a.check = true,
            "--official-expect" => a.official_expect = true,
            "--sample" => {
                let v = val("--sample")?;
                a.sample = if v == "all" { None } else { Some(v.parse().map_err(|_| "bad --sample")?) };
            }
            "--rows" => a.rows = val("--rows")?.parse().map_err(|_| "bad --rows")?,
            other if a.cmd == "list" && unit_for_list.is_none() => unit_for_list = Some(other.to_string()),
            other => return Err(format!("unknown option {other}")),
        }
    }
    if let Some(u) = unit_for_list {
        a.only = None;
        a.cmd = format!("list:{u}");
    }
    Ok(a)
}

fn units_of(name: &str) -> Result<Vec<&'static str>, String> {
    if name == "all" {
        return Ok(UNITS.to_vec());
    }
    UNITS.iter().find(|u| **u == name).map(|u| vec![*u]).ok_or(format!("unknown unit {name} (units: {})", UNITS.join(", ")))
}

fn selected<'a>(specs: &'a [Box<dyn Spec>], only: &Option<String>) -> Vec<&'a Box<dyn Spec>> {
    specs.iter().filter(|s| only.as_ref().is_none_or(|o| s.stem().contains(o.as_str()))).collect()
}

fn cmd_generate(a: &Args, units: &[&str]) -> Result<(), String> {
    let out = a.out.clone().unwrap_or_else(|| repo_mncore().join("sim").join("vectors"));
    let mut sim = bb::SimBackend::new();
    for unit in units {
        let t0 = Instant::now();
        let specs = specs(unit);
        let mut rows = 0;
        let mut files = 0;
        if a.only.is_none() {
            // Remove files of an earlier run, so the directory holds exactly this unit.
            if let Ok(rd) = std::fs::read_dir(out.join(unit)) {
                for e in rd.flatten() {
                    if e.path().extension().is_some_and(|x| x == "vec") {
                        let _ = std::fs::remove_file(e.path());
                    }
                }
            }
        }
        for s in selected(&specs, &a.only) {
            let f = generate(s.as_ref(), a.n, a.seed, &mut sim)?;
            let path = out.join(unit).join(format!("{}.vec", s.stem()));
            f.write(&path).map_err(|e| format!("{}: {e}", path.display()))?;
            rows += f.rows.len();
            files += 1;
        }
        if *unit == "rrn" {
            for s in rrn::specs().iter().filter(|s| a.only.as_ref().is_none_or(|o| s.stem().contains(o.as_str()))) {
                let f = rrn::generate(s, a.n, a.seed, &mut sim)?;
                let path = out.join(unit).join(format!("{}.vec", s.stem()));
                f.write(&path).map_err(|e| format!("{}: {e}", path.display()))?;
                rows += f.rows.len();
                files += 1;
            }
        }
        println!(
            "{unit}: {files} files, {rows} rows -> {} ({:.1} s)",
            out.join(unit).display(),
            t0.elapsed().as_secs_f64()
        );
    }
    Ok(())
}

fn work_dir(a: &Args, unit: &str) -> PathBuf {
    a.work.clone().unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target").join("official")).join(unit)
}

/// Official check of the reduction unit (its own memory layout, one program per chunk).
fn cmd_check_rrn(a: &Args, input: &std::path::Path) -> Result<bool, String> {
    let t0 = Instant::now();
    let work = work_dir(a, "rrn");
    let mut jobs = Vec::new();
    let mut checks = Vec::new();
    for s in rrn::specs() {
        if !a.only.as_ref().is_none_or(|o| s.stem().contains(o.as_str())) {
            continue;
        }
        let path = input.join("rrn").join(format!("{}.vec", s.stem()));
        if !path.exists() {
            continue;
        }
        let f = VecFile::read(&path)?;
        let idx = sample_rows(&f, a.sample, &format!("rrn/{}", s.stem()));
        let rows: Vec<Vec<u64>> = idx.iter().map(|&i| f.rows[i].0.iter().map(|&x| x as u64).collect()).collect();
        let refs: Vec<&Vec<u64>> = rows.iter().collect();
        let js = s.official_jobs(&refs);
        let range = jobs.len()..jobs.len() + js.len();
        jobs.extend(js);
        checks.push((s, f, idx, rows, range));
    }
    if jobs.is_empty() {
        println!("rrn: no vector files in {}", input.join("rrn").display());
        return Ok(true);
    }
    let results = official::run_raw(&work, &jobs)?;
    let (mut n_rows, mut n_bad, mut n_files_bad) = (0, 0, 0);
    for (s, f, idx, rows, range) in &checks {
        let stem = s.stem();
        let dumps: Result<Vec<String>, String> = results[range.clone()].iter().map(|r| r.dump.clone()).collect();
        let refs: Vec<&Vec<u64>> = rows.iter().collect();
        let got = dumps.and_then(|d| s.parse_official(&refs, &d));
        let mut bad = 0;
        match got {
            Err(e) => {
                println!("  rrn/{stem}: {e}");
                bad = idx.len();
            }
            Ok(got) => {
                let mut log = String::new();
                for (k, &i) in idx.iter().enumerate() {
                    if got[k] as u128 != f.rows[i].1[0] {
                        bad += 1;
                        let official = f.format_row(&(f.rows[i].0.clone(), vec![got[k] as u128]));
                        log += &format!("line {}\n  vec:      {}\n  official: {}\n", i + 2, f.format_row(&f.rows[i]), official);
                        if bad <= 3 {
                            println!("  MISMATCH rrn/{stem} line {}:\n    vec:      {}\n    official: {}", i + 2, f.format_row(&f.rows[i]), official);
                        }
                    }
                }
                if bad > 0 {
                    let _ = std::fs::write(work.join(format!("{stem}.mismatch.txt")), format!("{}\n{log}", f.header()));
                }
            }
        }
        n_rows += idx.len();
        n_bad += bad;
        n_files_bad += (bad > 0) as usize;
    }
    println!(
        "rrn: official check of {} files, {n_rows} rows: {n_bad} mismatching rows in {n_files_bad} files ({:.1} s)",
        checks.len(),
        t0.elapsed().as_secs_f64()
    );
    Ok(n_bad == 0)
}

/// `--check-official` (`replace == false`): run sampled rows on the official tools and compare.
/// `--official-expect` (`replace == true`): run every row of the files marked `disputed` and
/// replace the expected columns of the rows where the official emulator differs, so that the
/// files follow the official emulator (the lead's decision for the WP03 disagreements). The
/// header keeps `disputed=` and gets `expect=official` and `replaced=<rows replaced>`.
fn cmd_check(a: &Args, units: &[&str], replace: bool) -> Result<bool, String> {
    let input = a.input.clone().unwrap_or_else(|| repo_mncore().join("sim").join("vectors"));
    let out_dir = a.out.clone().unwrap_or_else(|| input.clone());
    let mut all_ok = true;
    for unit in units {
        if *unit == "rrn" {
            if replace {
                // No reduction file disagrees with the emulator (none is marked disputed).
                println!("rrn: no files marked disputed");
            } else {
                all_ok &= cmd_check_rrn(a, &input)?;
            }
            continue;
        }
        let t0 = Instant::now();
        let specs = specs(unit);
        let mut jobs = Vec::new();
        let mut checks = Vec::new();
        for s in selected(&specs, &a.only) {
            let path = input.join(unit).join(format!("{}.vec", s.stem()));
            if !path.exists() {
                continue;
            }
            let f = VecFile::read(&path)?;
            let t = s.template();
            if f.get("op") != t.get("op") || f.cols_in.len() != t.cols_in.len() || f.cols_out.len() != t.cols_out.len() {
                return Err(format!("{}: header does not match the definition of {}", path.display(), s.stem()));
            }
            if replace && f.get("disputed").is_none() {
                continue;
            }
            let sample = if replace { None } else { a.sample };
            let idx = sample_rows(&f, sample, &format!("{unit}/{}", s.stem()));
            let rows: Vec<&Vec<u128>> = idx.iter().map(|&i| &f.rows[i].0).collect();
            let plan = s.plan(&rows);
            jobs.push(official::Job { name: s.stem().replace('.', "_"), blocks: plan.blocks.clone() });
            checks.push((s, f, idx, plan));
        }
        if jobs.is_empty() {
            if replace {
                println!("{unit}: no files marked disputed in {}", input.join(unit).display());
            } else {
                println!("{unit}: no vector files in {}", input.join(unit).display());
            }
            continue;
        }
        let work = work_dir(a, unit);
        let results = official::run_jobs(&work, &jobs)?;
        let (mut n_rows, mut n_bad, mut n_files_bad, mut n_field_bad, mut n_insn) = (0, 0, 0, 0, 0);
        let mut n_failed = 0;
        let n_files = checks.len();
        for ((s, mut f, idx, plan), res) in checks.into_iter().zip(results) {
            let stem = s.stem();
            let mut bad = 0;
            match &res.outs {
                Err(e) => {
                    println!("  {unit}/{stem}: {e}");
                    bad = idx.len();
                    n_failed += 1;
                }
                Ok(outs) => {
                    let rows: Vec<&Vec<u128>> = idx.iter().map(|&i| &f.rows[i].0).collect();
                    let got = s.outputs(&rows, &plan, outs);
                    let mut log = String::new();
                    let mut changes = Vec::new();
                    for (k, &i) in idx.iter().enumerate() {
                        if got[k] != f.rows[i].1 {
                            bad += 1;
                            let official = f.format_row(&(f.rows[i].0.clone(), got[k].clone()));
                            log += &format!("line {}\n  vec:      {}\n  official: {}\n", i + 2, f.format_row(&f.rows[i]), official);
                            if bad <= 3 && !replace {
                                println!(
                                    "  MISMATCH {unit}/{stem} line {}:\n    vec:      {}\n    official: {}",
                                    i + 2,
                                    f.format_row(&f.rows[i]),
                                    official
                                );
                            }
                            changes.push((i, got[k].clone()));
                        }
                    }
                    if bad > 0 {
                        let p = work.join(format!("{}.mismatch.txt", stem.replace('.', "_")));
                        let _ = std::fs::write(&p, format!("{}\n{log}", f.header()));
                    }
                    if replace {
                        let before: usize = f.get("replaced").and_then(|v| v.parse().ok()).unwrap_or(0);
                        for (i, o) in changes {
                            f.rows[i].1 = o;
                        }
                        f.set("expect", "official");
                        f.set("replaced", before + bad);
                        let path = out_dir.join(unit).join(format!("{stem}.vec"));
                        f.write(&path).map_err(|e| format!("{}: {e}", path.display()))?;
                    }
                }
            }
            match &res.fields {
                Err(e) => {
                    println!("  {unit}/{stem}: fields: {e}");
                    n_field_bad += 1;
                }
                Ok(map) => {
                    for (b, want) in plan.blocks.iter().zip(&plan.fields) {
                        n_insn += 1;
                        let Some(row) = map.get(&b.insn) else {
                            println!("  {unit}/{stem}: no CSV row for `{}`", b.insn);
                            n_field_bad += 1;
                            continue;
                        };
                        for (k, v) in want {
                            if row.get(k) != Some(v) {
                                println!("  FIELD {unit}/{stem} `{}`: {k} = {:?}, expected {v}", b.insn, row.get(k));
                                n_field_bad += 1;
                            }
                        }
                    }
                }
            }
            for e in &res.field_position_errors {
                println!("  POSITION {unit}/{stem}: {e}");
                n_field_bad += 1;
            }
            n_rows += idx.len();
            n_bad += bad;
            if bad > 0 {
                n_files_bad += 1;
            }
        }
        if replace {
            println!(
                "{unit}: official-expect of {n_files} disputed files, {n_rows} rows: {n_bad} rows replaced in {n_files_bad} files; \
                 {n_failed} files without an official result, {n_field_bad} field mismatches ({:.1} s)",
                t0.elapsed().as_secs_f64()
            );
            if n_failed > 0 || n_field_bad > 0 {
                all_ok = false;
            }
            continue;
        }
        println!(
            "{unit}: official check of {n_files} files, {n_rows} rows: {n_bad} mismatching rows in {n_files_bad} files; \
             {n_insn} instructions, {n_field_bad} field mismatches ({:.1} s)",
            t0.elapsed().as_secs_f64()
        );
        if n_bad > 0 || n_field_bad > 0 {
            all_ok = false;
        }
    }
    Ok(all_ok)
}

fn cmd_fixed(a: &Args) -> Result<(), String> {
    let input = a.input.clone().unwrap_or_else(|| repo_mncore().join("sim").join("vectors"));
    let out = a.out.clone().unwrap_or_else(|| repo_mncore().join("sim").join("vectors_fixed"));
    for unit in UNITS {
        let mut files = 0;
        if let Ok(rd) = std::fs::read_dir(out.join(unit)) {
            for e in rd.flatten() {
                if e.path().extension().is_some_and(|x| x == "vec") {
                    let _ = std::fs::remove_file(e.path());
                }
            }
        }
        let unit_specs = specs(unit);
        for (stem, sdm) in stems(unit) {
            if !sdm {
                continue;
            }
            let path = input.join(unit).join(format!("{stem}.vec"));
            let Ok(mut f) = VecFile::read(&path) else { continue };
            // Rows affected by a known disagreement with the official emulator are left out,
            // unless the file already takes those expected values from the emulator
            // (`--official-expect`): then every row follows the emulator.
            let spec = unit_specs.iter().find(|s| s.stem() == stem);
            let official = f.get("expect") == Some("official");
            let edge: usize = f.get("edge").and_then(|v| v.parse().ok()).unwrap_or(0);
            let ok: Vec<usize> = (0..f.rows.len())
                .filter(|&i| official || spec.is_none_or(|s| !s.row_disputed(&f.rows[i].0)))
                .collect();
            if ok.is_empty() {
                continue;
            }
            let mut g = f.clone();
            g.rows = ok.iter().map(|&i| f.rows[i].clone()).collect();
            g.set("edge", ok.iter().filter(|&&i| i < edge).count());
            let idx = sample_rows(&g, Some(a.rows), &format!("fixed/{unit}/{stem}"));
            let n_edge = idx.iter().filter(|&&i| ok[i] < edge).count();
            f.rows = idx.iter().map(|&i| g.rows[i].clone()).collect();
            f.set("edge", n_edge);
            f.set("rows", f.rows.len());
            if official {
                // The count of replaced rows belongs to the whole file, not to the sample.
                f.meta.retain(|(k, _)| k != "replaced");
            } else if let Some(d) = f.get("disputed").map(String::from) {
                f.meta.retain(|(k, _)| k != "disputed");
                f.set("excluded", d);
            }
            f.write(&out.join(unit).join(format!("{stem}.vec"))).map_err(|e| e.to_string())?;
            files += 1;
        }
        println!("fixed {unit}: {files} files -> {}", out.join(unit).display());
    }
    Ok(())
}

fn run() -> Result<bool, String> {
    let a = parse_args()?;
    if let Some(u) = a.cmd.strip_prefix("list:") {
        for unit in units_of(u)? {
            for (stem, sdm) in stems(unit) {
                println!("{unit}/{stem}{}", if sdm { "" } else { "  (sdm=no)" });
            }
        }
        return Ok(true);
    }
    if a.cmd == "fixed" {
        cmd_fixed(&a)?;
        return Ok(true);
    }
    let units = units_of(&a.cmd)?;
    if a.official_expect {
        cmd_check(&a, &units, true)
    } else if a.check {
        cmd_check(&a, &units, false)
    } else {
        cmd_generate(&a, &units)?;
        Ok(true)
    }
}

fn main() {
    match run() {
        Ok(true) => {}
        Ok(false) => std::process::exit(1),
        Err(e) => {
            eprintln!("vecgen: {e}");
            std::process::exit(2);
        }
    }
}
