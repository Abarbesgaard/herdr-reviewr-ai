//! The AI-review inbox: a transient handoff from the `review-herdr` subcommand to a running
//! reviewr pane (specs/ai-review.md).
//!
//! The subcommand computes comments out-of-process and writes them here; the pane picks them
//! up on its next poll, adds them to its in-memory store, and deletes the file. The inbox is
//! **not** a durable comment store — it holds one pending batch and is consumed on read,
//! keeping the **Comments survive** / in-memory-only model intact (specs/overview.md). It
//! lives under the temp dir, keyed by worktree, so it never writes into the repository (the
//! **No writes** invariant).

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::model::{Comment, Side};

/// One comment in the on-disk handoff. A stable, self-describing contract — deliberately not
/// the internal `Comment` type — so the subcommand and the pane can version independently.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboxComment {
    pub file: String,
    /// `"new"` for an added/context anchor, `"old"` for a removed one.
    pub side: String,
    pub start: u32,
    pub end: u32,
    /// The verbatim diff lines the comment anchors to, each keeping its `+`/`-`/space marker.
    pub lines: String,
    pub text: String,
}

/// The whole handoff: the reviewed scope's comments plus the format version.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Inbox {
    /// The handoff format version, so a stale pane can reject a batch it can't read.
    #[serde(default)]
    pub version: u32,
    pub comments: Vec<InboxComment>,
}

/// The current handoff format version.
pub const VERSION: u32 = 1;

/// The inbox path for one worktree: under the temp dir, keyed by the worktree, so a
/// subcommand run anywhere in the worktree and the pane watching it agree on one file, and
/// nothing is ever written inside the repository.
pub fn path(repo: &Path) -> PathBuf {
    let key = crate::git::worktree_key(repo);
    std::env::temp_dir().join("herdr-reviewr-ai").join(format!("{key}.json"))
}

/// Write a batch of comments to the worktree's inbox, replacing any pending one. The parent
/// dir is created on demand.
pub fn write(repo: &Path, comments: Vec<InboxComment>) -> std::io::Result<()> {
    let path = path(repo);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let inbox = Inbox { version: VERSION, comments };
    let json = serde_json::to_string_pretty(&inbox)?;
    std::fs::write(&path, json)
}

/// Take the pending batch for a worktree: read it, delete the file, and return its comments.
/// `None` when there is no pending batch, or it is unreadable or a version the pane can't
/// read — the file is removed either way so a poisoned batch can't wedge the pane.
pub fn take(repo: &Path) -> Option<Vec<InboxComment>> {
    let path = path(repo);
    let text = std::fs::read_to_string(&path).ok()?;
    let _ = std::fs::remove_file(&path);
    let inbox: Inbox = serde_json::from_str(&text).ok()?;
    if inbox.version != VERSION {
        return None;
    }
    Some(inbox.comments)
}

/// Map a handoff comment onto the in-memory model. AI comments always anchor to the diff
/// (the `Changes` view), so `diff_anchored` is true. An unknown `side` string is dropped.
pub fn to_comment(c: InboxComment) -> Option<Comment> {
    let side = match c.side.as_str() {
        "new" => Side::New,
        "old" => Side::Old,
        _ => return None,
    };
    Some(Comment {
        id: 0,
        file: c.file,
        side,
        start: c.start,
        end: c.end,
        lines: c.lines,
        text: c.text,
        diff_anchored: true,
    })
}

#[cfg(test)]
mod tests {
    use super::{Inbox, InboxComment, VERSION, to_comment};
    use crate::model::Side;

    fn sample() -> InboxComment {
        InboxComment {
            file: "src/x.rs".into(),
            side: "new".into(),
            start: 12,
            end: 12,
            lines: "+let x = foo();".into(),
            text: "unchecked unwrap".into(),
        }
    }

    #[test]
    fn round_trips_through_json() {
        let inbox = Inbox { version: VERSION, comments: vec![sample()] };
        let json = serde_json::to_string(&inbox).unwrap();
        let back: Inbox = serde_json::from_str(&json).unwrap();
        assert_eq!(back.comments, vec![sample()]);
    }

    #[test]
    fn maps_sides_and_rejects_unknown() {
        let c = to_comment(sample()).unwrap();
        assert_eq!(c.side, Side::New);
        assert!(c.diff_anchored);
        let mut old = sample();
        old.side = "old".into();
        assert_eq!(to_comment(old).unwrap().side, Side::Old);
        let mut bad = sample();
        bad.side = "sideways".into();
        assert!(to_comment(bad).is_none());
    }
}
