//! In-memory review model: scopes, changed files, and comments.
//!
//! See `specs/review-model.md`. Comments live only for the session and are
//! removed by export or delete — never by a refresh.

/// Which set of changes the Changes view shows.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Scope {
    Uncommitted,
    Branch,
    LastTurn,
}

impl Scope {
    pub fn label(self) -> &'static str {
        match self {
            Scope::Uncommitted => "uncommitted",
            Scope::Branch => "branch",
            Scope::LastTurn => "last turn",
        }
    }

    /// The scope's name in the specs and in config values (`default_scope`): kebab-case,
    /// unlike the header chip's spaced `label`.
    pub fn name(self) -> &'static str {
        match self {
            Scope::Uncommitted => "uncommitted",
            Scope::Branch => "branch",
            Scope::LastTurn => "last-turn",
        }
    }

    /// Cycle to the next scope, for the header chip click: uncommitted → branch → last turn.
    #[must_use]
    pub fn cycle(self) -> Self {
        match self {
            Scope::Uncommitted => Scope::Branch,
            Scope::Branch => Scope::LastTurn,
            Scope::LastTurn => Scope::Uncommitted,
        }
    }
}

/// How a file changed within a scope.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ChangeKind {
    Added,
    Modified,
    Deleted,
    Renamed,
    Untracked,
}

impl ChangeKind {
    pub fn marker(self) -> char {
        match self {
            ChangeKind::Added => 'A',
            ChangeKind::Modified => 'M',
            ChangeKind::Deleted => 'D',
            ChangeKind::Renamed => 'R',
            ChangeKind::Untracked => '?',
        }
    }
}

/// A row in the Changes list.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct ChangedFile {
    pub path: String,
    pub kind: ChangeKind,
    pub additions: u32,
    pub deletions: u32,
    /// The old path of a renamed file; `None` for every other kind. Its old content lives
    /// at this path, so a rename diffs real content instead of reading as all-insertion.
    pub previous_path: Option<String>,
}

/// Which side of the diff a comment's lines live on.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Side {
    New,
    Old,
}

/// A reviewer comment anchored to a run of diff lines, carrying the snippet.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Comment {
    /// A stable per-store id, stamped on [`CommentStore::add`]. It survives edits and the
    /// shifting of neighbours, so an out-of-process agent handed this id in an address prompt
    /// can name exactly this comment back to `resolve-herdr` however long the fix takes. The
    /// literal `0` on a freshly built comment is a placeholder the store overwrites.
    pub id: u64,
    pub file: String,
    pub side: Side,
    pub start: u32,
    pub end: u32,
    /// Verbatim diff lines the comment anchors to, each keeping its `+`/`-`/space marker.
    pub lines: String,
    pub text: String,
    /// True when anchored to a diff (the `Changes` tab); false for a File-view content comment
    /// (the `All files` tab). Selects how staleness is judged (specs/review-model.md).
    pub diff_anchored: bool,
}

impl Comment {
    /// The `path:start-end` (or `path:line`) location, with ` (removed)` when old-side.
    pub fn location(&self) -> String {
        let range = if self.start == self.end {
            format!("{}:{}", self.file, self.start)
        } else {
            format!("{}:{}-{}", self.file, self.start, self.end)
        };
        match self.side {
            Side::New => range,
            Side::Old => format!("{range} (removed)"),
        }
    }
}

/// The in-memory comment list for one worktree review session.
#[derive(Default, Debug)]
pub struct CommentStore {
    items: Vec<Comment>,
    /// The last id stamped; the next `add` uses `next_id + 1`, so ids start at 1 and never
    /// repeat within a session — a resolve can't clear the wrong comment by id reuse.
    next_id: u64,
}

impl CommentStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    pub fn iter(&self) -> impl Iterator<Item = &Comment> {
        self.items.iter()
    }

    pub fn get(&self, index: usize) -> Option<&Comment> {
        self.items.get(index)
    }

    /// Append a comment, stamping it with the next session id; returns its index.
    pub fn add(&mut self, mut comment: Comment) -> usize {
        self.next_id += 1;
        comment.id = self.next_id;
        self.items.push(comment);
        self.items.len() - 1
    }

    /// Replace the text of the comment at `index`. Returns `false` if out of range.
    pub fn edit(&mut self, index: usize, text: String) -> bool {
        if let Some(c) = self.items.get_mut(index) {
            c.text = text;
            true
        } else {
            false
        }
    }

    /// Remove and return the comment at `index` (delete, or consume one on export).
    pub fn take(&mut self, index: usize) -> Option<Comment> {
        if index < self.items.len() { Some(self.items.remove(index)) } else { None }
    }

    /// Remove and return every comment (consume-all on a successful export).
    pub fn take_all(&mut self) -> Vec<Comment> {
        std::mem::take(&mut self.items)
    }

    /// Drop every comment whose id is in `ids` (an agent- or reviewer-driven resolve); returns
    /// how many were removed. An id with no live comment — already gone, or never here — is a
    /// silent no-op, so a duplicate or stale resolve is harmless.
    pub fn resolve(&mut self, ids: &std::collections::HashSet<u64>) -> usize {
        let before = self.items.len();
        self.items.retain(|c| !ids.contains(&c.id));
        before - self.items.len()
    }
}

#[cfg(test)]
mod tests {
    use super::{Comment, CommentStore, Scope, Side};

    fn comment(file: &str, start: u32, end: u32, text: &str) -> Comment {
        Comment {
            id: 0,
            file: file.into(),
            side: Side::New,
            start,
            end,
            lines: "+x".into(),
            text: text.into(),
            diff_anchored: true,
        }
    }

    #[test]
    fn scope_cycles_and_labels() {
        // The chip click cycles through all three scopes and wraps.
        assert_eq!(Scope::Uncommitted.cycle(), Scope::Branch);
        assert_eq!(Scope::Branch.cycle(), Scope::LastTurn);
        assert_eq!(Scope::LastTurn.cycle(), Scope::Uncommitted);
        assert_eq!(Scope::Uncommitted.label(), "uncommitted");
        assert_eq!(Scope::LastTurn.label(), "last turn");
    }

    #[test]
    fn location_formats_range_single_and_removed() {
        let mut c = comment("a.rs", 40, 52, "x");
        assert_eq!(c.location(), "a.rs:40-52");
        c.end = 40;
        assert_eq!(c.location(), "a.rs:40");
        c.side = Side::Old;
        assert_eq!(c.location(), "a.rs:40 (removed)");
    }

    #[test]
    fn add_get_edit() {
        let mut s = CommentStore::new();
        let i = s.add(comment("a.rs", 1, 1, "first"));
        assert_eq!(s.len(), 1);
        assert_eq!(s.get(i).unwrap().text, "first");
        assert!(s.edit(i, "second".into()));
        assert_eq!(s.get(i).unwrap().text, "second");
        assert!(!s.edit(99, "nope".into()));
    }

    #[test]
    fn take_one_and_take_all_consume() {
        let mut s = CommentStore::new();
        s.add(comment("a.rs", 1, 1, "one"));
        s.add(comment("b.rs", 2, 2, "two"));
        let taken = s.take(0).unwrap();
        assert_eq!(taken.text, "one");
        assert_eq!(s.len(), 1);
        let rest = s.take_all();
        assert_eq!(rest.len(), 1);
        assert!(s.is_empty());
        assert!(s.take(0).is_none());
    }

    #[test]
    fn add_stamps_rising_ids_and_resolve_drops_by_id() {
        let mut s = CommentStore::new();
        s.add(comment("a.rs", 1, 1, "one"));
        s.add(comment("b.rs", 2, 2, "two"));
        s.add(comment("c.rs", 3, 3, "three"));
        let ids: Vec<u64> = s.iter().map(|c| c.id).collect();
        assert_eq!(ids, vec![1, 2, 3], "ids start at 1 and rise, so none collides");

        let want: std::collections::HashSet<u64> = [2, 42].into_iter().collect();
        assert_eq!(s.resolve(&want), 1, "only the live id resolves; the stranger is ignored");
        let left: Vec<u64> = s.iter().map(|c| c.id).collect();
        assert_eq!(left, vec![1, 3], "the resolved comment is dropped, the rest keep their ids");
    }
}
