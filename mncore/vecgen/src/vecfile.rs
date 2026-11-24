//! The `.vec` file format (contract section 5, details in FORMAT.md).
//!
//! ```text
//! # vec v1 unit=alu op=iadd ... cols: ra rb x_hi x_lo y_hi y_lo | z_hi z_lo flags
//! 0 0 0000000100000002 ffffffffffffffff 0000000300000004 0000000000000000 | 0000000400000006 ffffffffffffffff f
//! ```
//!
//! Every value is lower-case hex with a fixed number of digits per column.

use std::fmt::Write as _;
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Col {
    pub name: String,
    /// Hex digits written for this column.
    pub digits: usize,
}

pub fn col(name: &str, digits: usize) -> Col {
    Col { name: name.to_string(), digits }
}

pub type Row = (Vec<u128>, Vec<u128>);

#[derive(Clone, Debug, Default)]
pub struct VecFile {
    /// `key=value` pairs of the header, in order (`unit` and `op` first).
    pub meta: Vec<(String, String)>,
    pub cols_in: Vec<Col>,
    pub cols_out: Vec<Col>,
    pub rows: Vec<Row>,
}

impl VecFile {
    pub fn get(&self, key: &str) -> Option<&str> {
        self.meta.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }

    pub fn set(&mut self, key: &str, value: impl ToString) {
        let value = value.to_string();
        match self.meta.iter_mut().find(|(k, _)| k == key) {
            Some(kv) => kv.1 = value,
            None => self.meta.push((key.to_string(), value)),
        }
    }

    pub fn header(&self) -> String {
        let mut s = String::from("# vec v1");
        for (k, v) in &self.meta {
            write!(s, " {k}={v}").unwrap();
        }
        s += " cols:";
        for c in &self.cols_in {
            write!(s, " {}", c.name).unwrap();
        }
        s += " |";
        for c in &self.cols_out {
            write!(s, " {}", c.name).unwrap();
        }
        s
    }

    pub fn format_row(&self, row: &Row) -> String {
        let mut s = String::with_capacity(16 * (row.0.len() + row.1.len()) + 8);
        for (i, (v, c)) in row.0.iter().zip(&self.cols_in).enumerate() {
            if i > 0 {
                s.push(' ');
            }
            write!(s, "{:0w$x}", v, w = c.digits).unwrap();
        }
        s += " |";
        for (v, c) in row.1.iter().zip(&self.cols_out) {
            write!(s, " {:0w$x}", v, w = c.digits).unwrap();
        }
        s
    }

    pub fn to_text(&self) -> String {
        let mut s = self.header();
        s.push('\n');
        for r in &self.rows {
            s += &self.format_row(r);
            s.push('\n');
        }
        s
    }

    pub fn write(&self, path: &Path) -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::write(path, self.to_text())
    }

    pub fn parse(text: &str) -> Result<VecFile, String> {
        let mut lines = text.lines();
        let head = lines.next().ok_or("empty file")?;
        let rest = head.strip_prefix("# vec v1").ok_or("first line must start with `# vec v1`")?;
        let (meta_part, cols_part) = rest.split_once(" cols:").ok_or("header has no `cols:`")?;
        let mut f = VecFile::default();
        for kv in meta_part.split_whitespace() {
            let (k, v) = kv.split_once('=').ok_or_else(|| format!("bad header item `{kv}`"))?;
            f.meta.push((k.to_string(), v.to_string()));
        }
        let (ins, outs) = cols_part.split_once('|').ok_or("cols: has no `|`")?;
        f.cols_in = ins.split_whitespace().map(|n| col(n, 0)).collect();
        f.cols_out = outs.split_whitespace().map(|n| col(n, 0)).collect();
        let parse_side = |s: &str, n: usize, lineno: usize| -> Result<Vec<u128>, String> {
            let v: Vec<u128> = s
                .split_whitespace()
                .map(|t| u128::from_str_radix(t, 16).map_err(|_| format!("line {lineno}: bad hex `{t}`")))
                .collect::<Result<_, _>>()?;
            if v.len() != n {
                return Err(format!("line {lineno}: {} values, expected {n}", v.len()));
            }
            Ok(v)
        };
        let mut widths_in = vec![0usize; f.cols_in.len()];
        let mut widths_out = vec![0usize; f.cols_out.len()];
        for (i, line) in lines.enumerate() {
            let lineno = i + 2;
            if line.trim().is_empty() || line.starts_with('#') {
                continue;
            }
            let (l, r) = line.split_once('|').ok_or_else(|| format!("line {lineno}: no `|`"))?;
            for (w, t) in widths_in.iter_mut().zip(l.split_whitespace()) {
                *w = (*w).max(t.len());
            }
            for (w, t) in widths_out.iter_mut().zip(r.split_whitespace()) {
                *w = (*w).max(t.len());
            }
            f.rows.push((parse_side(l, f.cols_in.len(), lineno)?, parse_side(r, f.cols_out.len(), lineno)?));
        }
        for (c, w) in f.cols_in.iter_mut().zip(widths_in) {
            c.digits = w;
        }
        for (c, w) in f.cols_out.iter_mut().zip(widths_out) {
            c.digits = w;
        }
        Ok(f)
    }

    pub fn read(path: &Path) -> Result<VecFile, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        VecFile::parse(&text).map_err(|e| format!("{}: {e}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let mut f = VecFile::default();
        f.set("unit", "alu");
        f.set("op", "iadd");
        f.cols_in = vec![col("x", 16), col("y", 16)];
        f.cols_out = vec![col("z", 16), col("flags", 1)];
        f.rows.push((vec![1, 2], vec![3, 0xf]));
        let t = f.to_text();
        assert_eq!(t.lines().nth(1).unwrap(), "0000000000000001 0000000000000002 | 0000000000000003 f");
        let g = VecFile::parse(&t).unwrap();
        assert_eq!(g.rows, f.rows);
        assert_eq!(g.get("op"), Some("iadd"));
        assert_eq!(g.cols_in, f.cols_in);
        assert_eq!(g.cols_out, f.cols_out);
    }
}
