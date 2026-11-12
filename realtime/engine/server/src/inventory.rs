//! OSC destinations from an Ansible INI inventory group (`osc.inventory`).
//!
//! Every host in the group gets its own unicast copy of each OSC packet
//! (reliable on Wi-Fi, unlike subnet broadcast). The file is re-read when its
//! mtime changes, so adding / removing a laptop in the inventory takes effect
//! without a restart.

use crate::config::{InventoryCfg, OscDest};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

const CHECK_EVERY: Duration = Duration::from_secs(2);

/// Hosts listed under `[group]`: the first token of each line, or its
/// `ansible_host=` value when present. Comments / blank lines are skipped;
/// `[group:children]` / `[group:vars]` sections are not this group.
pub fn parse_group(text: &str, group: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut inside = false;
    for line in text.lines() {
        let l = line.trim();
        if l.is_empty() || l.starts_with('#') || l.starts_with(';') {
            continue;
        }
        if l.starts_with('[') && l.ends_with(']') {
            inside = l[1..l.len() - 1].trim() == group;
            continue;
        }
        if !inside {
            continue;
        }
        let mut toks = l.split_whitespace();
        let Some(first) = toks.next() else { continue };
        let host = toks
            .find_map(|t| t.strip_prefix("ansible_host="))
            .unwrap_or(first)
            .trim_matches(|c| c == '"' || c == '\'');
        if !out.iter().any(|h| h == host) {
            out.push(host.to_string());
        }
    }
    out
}

pub struct InventoryWatch {
    pub path: PathBuf,
    group: String,
    port: i64,
    mtime: Option<SystemTime>,
    next_check: Instant,
}

impl InventoryWatch {
    /// `path` is resolved relative to the config file's directory.
    pub fn new(cfg: &InventoryCfg, config_dir: &Path) -> Self {
        let p = PathBuf::from(&cfg.path);
        let path = if p.is_absolute() { p } else { config_dir.join(p) };
        InventoryWatch { path, group: cfg.group.clone(), port: cfg.port, mtime: None, next_check: Instant::now() }
    }

    /// The group's hosts as OSC destinations when the file changed since the
    /// last call (always on the first call), else `None`. Rate-limited.
    pub fn poll(&mut self, now: Instant) -> Option<Vec<OscDest>> {
        if now < self.next_check {
            return None;
        }
        self.next_check = now + CHECK_EVERY;
        let mtime = std::fs::metadata(&self.path).and_then(|m| m.modified()).ok();
        if mtime.is_some() && mtime == self.mtime {
            return None;
        }
        let first = self.mtime.is_none();
        self.mtime = mtime;
        let text = match std::fs::read_to_string(&self.path) {
            Ok(t) => t,
            Err(e) => {
                if first {
                    tracing::warn!("osc inventory {} unreadable ({e}); no inventory hosts", self.path.display());
                }
                return if first { Some(Vec::new()) } else { None };
            }
        };
        let hosts = parse_group(&text, &self.group);
        if hosts.is_empty() {
            tracing::warn!("osc inventory {}: group [{}] has no hosts", self.path.display(), self.group);
        }
        Some(hosts.into_iter().map(|host| OscDest { host, port: self.port }).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_group_hosts() {
        let t = "[meat]\n10.0.0.1 ansible_user=a\n# 10.0.0.9 x\n10.0.0.2 ansible_host=10.0.0.3 ansible_user=b\n10.0.0.1\n\n[meat2]\n10.0.0.5\n[meat:vars]\nx=1\n";
        assert_eq!(parse_group(t, "meat"), vec!["10.0.0.1", "10.0.0.3"]);
        assert_eq!(parse_group(t, "meat2"), vec!["10.0.0.5"]);
        assert!(parse_group(t, "nope").is_empty());
    }
}
