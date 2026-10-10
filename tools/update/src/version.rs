//! Lenient version parsing and `constraint` matching.
//!
//! Versions are dot-separated numeric components with an optional leading
//! `v` (`1.96.4`, `v0.34`, `2026.4.1`). Anything else (`-rc1`, `latest`) is
//! not a stable version and never selected as an update.

use std::cmp::Ordering;

#[derive(Debug, Clone)]
pub struct Version(Vec<u64>);

impl Version {
    pub fn parse(s: &str) -> Option<Self> {
        let s = s.strip_prefix('v').unwrap_or(s);
        if s.is_empty() {
            return None;
        }
        s.split('.')
            .map(|c| c.parse::<u64>().ok())
            .collect::<Option<Vec<_>>>()
            .map(Version)
    }

    fn get(&self, i: usize) -> u64 {
        self.0.get(i).copied().unwrap_or(0)
    }
}

impl Ord for Version {
    fn cmp(&self, other: &Self) -> Ordering {
        let n = self.0.len().max(other.0.len());
        (0..n)
            .map(|i| self.get(i).cmp(&other.get(i)))
            .find(|o| o.is_ne())
            .unwrap_or(Ordering::Equal)
    }
}

impl PartialEq for Version {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other).is_eq()
    }
}

impl Eq for Version {}

impl PartialOrd for Version {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Op {
    Lt,
    Le,
    Gt,
    Ge,
    Eq,
    /// `^1.2` → `>=1.2, <2` (`^0.3` → `<0.4`)
    Caret,
    /// `~1.2` → `>=1.2, <1.3`
    Tilde,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Constraint(Vec<(Op, Version)>);

impl Constraint {
    /// Comma-separated bounds, e.g. `">=1.0, <1.98"`.
    pub fn parse(s: &str) -> Result<Self, String> {
        s.split(',')
            .map(str::trim)
            .filter(|p| !p.is_empty())
            .map(|part| {
                let (op, rest) = [
                    ("<=", Op::Le),
                    (">=", Op::Ge),
                    ("==", Op::Eq),
                    ("<", Op::Lt),
                    (">", Op::Gt),
                    ("=", Op::Eq),
                    ("^", Op::Caret),
                    ("~", Op::Tilde),
                ]
                .iter()
                .find_map(|(p, op)| part.strip_prefix(p).map(|r| (*op, r)))
                .unwrap_or((Op::Eq, part));
                Version::parse(rest.trim())
                    .map(|v| (op, v))
                    .ok_or_else(|| format!("bad constraint {part:?}"))
            })
            .collect::<Result<Vec<_>, _>>()
            .map(Constraint)
    }

    pub fn matches(&self, v: &Version) -> bool {
        self.0.iter().all(|(op, b)| match op {
            Op::Lt => v < b,
            Op::Le => v <= b,
            Op::Gt => v > b,
            Op::Ge => v >= b,
            Op::Eq => v == b,
            Op::Caret => v >= b && v < &caret_upper(b),
            Op::Tilde => v >= b && v < &tilde_upper(b),
        })
    }
}

fn caret_upper(b: &Version) -> Version {
    let i = b.0.iter().position(|&c| c != 0).unwrap_or(b.0.len() - 1);
    bump_at(b, i)
}

fn tilde_upper(b: &Version) -> Version {
    bump_at(b, if b.0.len() > 1 { 1 } else { 0 })
}

fn bump_at(b: &Version, i: usize) -> Version {
    let mut v: Vec<u64> = b.0.iter().take(i + 1).copied().collect();
    v[i] += 1;
    Version(v)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(s: &str) -> Version {
        Version::parse(s).unwrap()
    }

    #[test]
    fn parses_lenient() {
        assert_eq!(v("v1.55"), v("1.55.0"));
        assert!(Version::parse("1.0-rc1").is_none());
        assert!(Version::parse("latest").is_none());
        assert!(Version::parse("").is_none());
        assert!(v("1.10") > v("1.9.9"));
        assert!(v("2026.4.1") > v("2026.3.10"));
    }

    #[test]
    fn constraints() {
        let c = Constraint::parse("<1.98").unwrap();
        assert!(c.matches(&v("1.96.4")));
        assert!(!c.matches(&v("1.98.0")));
        let c = Constraint::parse(">=1.0, <2").unwrap();
        assert!(c.matches(&v("1.5")) && !c.matches(&v("2.0")) && !c.matches(&v("0.9")));
        let c = Constraint::parse("^0.3.1").unwrap();
        assert!(c.matches(&v("0.3.9")) && !c.matches(&v("0.4.0")));
        let c = Constraint::parse("^1.2").unwrap();
        assert!(c.matches(&v("1.9")) && !c.matches(&v("2.0")));
        let c = Constraint::parse("~1.2").unwrap();
        assert!(c.matches(&v("1.2.7")) && !c.matches(&v("1.3")));
        assert!(Constraint::parse("<x").is_err());
    }
}
