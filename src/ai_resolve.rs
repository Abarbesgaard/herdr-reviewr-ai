//! The AI-review resolve inbox: a transient handoff from the `resolve-herdr` subcommand back
//! to a running reviewr pane (specs/ai-review.md).
//!
//! Addressing a comment (`a`) drafts a prompt naming the comment's id and does not remove it;
//! the finding stays on the reviewer's checklist until it is actually fixed. When the agent
//! (or the reviewer) finishes, `herdr-reviewr resolve-herdr <id>...` appends those ids here;
//! the pane picks them up on its next poll and drops the matching comments. This is the return
//! leg of the one-way `ai_inbox` handoff, and obeys the same rules: temp-dir only (the **No
//! writes** invariant), keyed by worktree, and consumed on read.
//!
//! Unlike the review inbox, which holds one batch and is replaced whole, resolves accumulate:
//! several comments may be fixed between two polls, so `append` merges into the pending set
//! rather than overwriting it.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// The pending resolve set: comment ids the pane should drop, plus the format version.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Resolve {
    /// The handoff format version, so a stale pane can reject a set it can't read.
    #[serde(default)]
    pub version: u32,
    pub ids: Vec<u64>,
}

/// The current handoff format version.
pub const VERSION: u32 = 1;

/// The resolve-inbox path for one worktree: alongside the review inbox under the temp dir and
/// keyed by the same worktree key, so a `resolve-herdr` run anywhere in the worktree and the
/// pane watching it agree on one file, and nothing is ever written inside the repository.
pub fn path(repo: &Path) -> PathBuf {
    let key = crate::git::worktree_key(repo);
    std::env::temp_dir().join("herdr-reviewr-ai").join(format!("{key}.resolve.json"))
}

/// Merge `ids` into the worktree's pending resolve set, creating it on demand. Existing ids are
/// kept and duplicates collapse, so two `resolve-herdr` runs before a poll both land and a
/// repeated id is harmless.
pub fn append(repo: &Path, ids: &[u64]) -> std::io::Result<()> {
    let path = path(repo);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    // A prior set that is unreadable or a version we can't extend is discarded, not merged:
    // the new ids define a fresh, readable set rather than inheriting a poisoned one.
    let mut merged: Vec<u64> = std::fs::read_to_string(&path)
        .ok()
        .and_then(|t| serde_json::from_str::<Resolve>(&t).ok())
        .filter(|r| r.version == VERSION)
        .map(|r| r.ids)
        .unwrap_or_default();
    for &id in ids {
        if !merged.contains(&id) {
            merged.push(id);
        }
    }
    let resolve = Resolve { version: VERSION, ids: merged };
    let json = serde_json::to_string_pretty(&resolve)?;
    std::fs::write(&path, json)
}

/// Take the pending resolve set for a worktree: read it, delete the file, and return its ids.
/// `None` when there is nothing pending, or it is unreadable or a version the pane can't read
/// — the file is removed either way so a poisoned set can't wedge the pane.
pub fn take(repo: &Path) -> Option<Vec<u64>> {
    let path = path(repo);
    let text = std::fs::read_to_string(&path).ok()?;
    let _ = std::fs::remove_file(&path);
    let resolve: Resolve = serde_json::from_str(&text).ok()?;
    if resolve.version != VERSION {
        return None;
    }
    Some(resolve.ids)
}

#[cfg(test)]
mod tests {
    use super::{Resolve, VERSION, append, take};

    #[test]
    fn round_trips_through_json() {
        let set = Resolve { version: VERSION, ids: vec![3, 7] };
        let json = serde_json::to_string(&set).unwrap();
        let back: Resolve = serde_json::from_str(&json).unwrap();
        assert_eq!(back.ids, vec![3, 7]);
    }

    #[test]
    fn appends_merge_and_dedup_then_take_consumes() {
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path();
        // No git worktree here, but `worktree_key` falls back to the path, so `path()` is
        // stable for this dir across the calls below.
        append(repo, &[1, 2]).unwrap();
        append(repo, &[2, 5]).unwrap();
        let mut ids = take(repo).unwrap();
        ids.sort_unstable();
        assert_eq!(ids, vec![1, 2, 5], "two runs merge and the shared id collapses");
        assert!(take(repo).is_none(), "the set is consumed on read");
    }
}
