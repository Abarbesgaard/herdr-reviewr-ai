//! The `review-herdr` subcommand: review the uncommitted changeset with the Copilot CLI and
//! drop the resulting comments into the worktree's inbox for a running reviewr pane to show
//! (specs/ai-review.md).
//!
//! This runs as a transient, non-UI process (see `main.rs` pane-identity dispatch). It reads
//! the repo but never writes to it: the diff is computed with git, the engine runs read-only
//! (`ai_review`), and the only output is the temp-dir inbox (`ai_inbox`).

use std::path::Path;

use anyhow::Result;

use crate::ai_inbox::{self, InboxComment};
use crate::ai_review::{self, AiOutcome, DiffLine};
use crate::model::{ChangeKind, ChangedFile, Scope};

/// What a review run produced, for the caller's summary line.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Summary {
    pub files_reviewed: usize,
    pub comments: usize,
    /// Per-file engine failures, as `path: reason`. A file that fails is skipped, not fatal.
    pub errors: Vec<String>,
}

/// Review the uncommitted changeset and write its comments to the worktree inbox. Returns a
/// summary; the pending inbox is replaced whole, so a re-run supersedes an unread batch.
pub fn run(repo: &Path) -> Result<Summary> {
    let files = crate::git::changed_files(repo, Scope::Uncommitted, None, &[])?;
    let mut summary = Summary::default();
    let mut comments: Vec<InboxComment> = Vec::new();

    for file in &files {
        // A deletion has no new-side lines to anchor to; a rename with no content change adds
        // nothing to review. Both still list in reviewr — the AI pass just skips them.
        if file.kind == ChangeKind::Deleted {
            continue;
        }
        let lines = match new_side_lines(repo, file) {
            Some(lines) if !lines.is_empty() => lines,
            _ => continue,
        };
        summary.files_reviewed += 1;
        match ai_review::review_file(&file.path, &lines) {
            AiOutcome::Findings(findings) => {
                for f in findings {
                    // Anchor to the exact diff line the engine cited; drop a hallucinated
                    // line number that isn't in what we sent.
                    let Some(line) = lines.iter().find(|l| l.new_no == f.line) else { continue };
                    comments.push(InboxComment {
                        file: file.path.clone(),
                        side: "new".to_string(),
                        start: f.line,
                        end: f.line,
                        lines: line.marker_text.clone(),
                        text: f.comment,
                    });
                }
            }
            AiOutcome::Error(e) => summary.errors.push(format!("{}: {e}", file.path)),
        }
    }

    summary.comments = comments.len();
    ai_inbox::write(repo, comments)?;
    Ok(summary)
}

/// The new-side lines of a file's uncommitted diff — each carrying its line number and
/// marker-prefixed text — the unit the engine reviews and a comment anchors to. Untracked
/// files aren't in the diff base, so their whole content reads as additions.
fn new_side_lines(repo: &Path, file: &ChangedFile) -> Option<Vec<DiffLine>> {
    if file.kind == ChangeKind::Untracked {
        let content = std::fs::read_to_string(repo.join(&file.path)).ok()?;
        return Some(
            content
                .lines()
                .enumerate()
                .map(|(i, text)| DiffLine {
                    new_no: (i + 1) as u32,
                    marker_text: format!("+{text}"),
                })
                .collect(),
        );
    }
    let diff = crate::git::unified_diff(repo, &file.path).ok()?;
    Some(parse_new_side(&diff))
}

/// Parse a unified diff into its new-side lines (additions and context), tracking the new
/// file's line numbers across hunks. Deletions carry no new-side number and are dropped, so
/// every returned line anchors cleanly on the `new` side.
fn parse_new_side(diff: &str) -> Vec<DiffLine> {
    let mut out = Vec::new();
    let mut new_no = 0_u32;
    for line in diff.lines() {
        if let Some(rest) = line.strip_prefix("@@") {
            // `@@ -a,b +c,d @@` — start the new-side counter at `c`.
            if let Some(plus) = rest.split('+').nth(1) {
                let num: String = plus.chars().take_while(char::is_ascii_digit).collect();
                new_no = num.parse().unwrap_or(1);
            }
            continue;
        }
        // File headers share `+`/`-` prefixes with content; skip them explicitly.
        if line.starts_with("+++") || line.starts_with("---") || line.starts_with("diff ") {
            continue;
        }
        if let Some(b'+' | b' ') = line.as_bytes().first() {
            // Additions and context both advance the new-side counter and anchor a comment.
            // A deletion (`-`) has no new-side line, and a metadata line (`\ No newline`,
            // `index …`, a blank trailer) is not diff content — neither advances the counter.
            out.push(DiffLine { new_no, marker_text: line.to_string() });
            new_no += 1;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::parse_new_side;

    #[test]
    fn numbers_new_side_across_a_hunk() {
        let diff = "diff --git a/x b/x\n\
                    --- a/x\n\
                    +++ b/x\n\
                    @@ -1,3 +1,4 @@\n\
                    \x20ctx one\n\
                    -gone\n\
                    +added a\n\
                    +added b\n\
                    \x20ctx two\n";
        let lines = parse_new_side(diff);
        let got: Vec<(u32, &str)> =
            lines.iter().map(|l| (l.new_no, l.marker_text.as_str())).collect();
        assert_eq!(got, vec![(1, " ctx one"), (2, "+added a"), (3, "+added b"), (4, " ctx two"),]);
    }

    #[test]
    fn resumes_numbering_on_a_second_hunk() {
        let diff = "@@ -1 +1 @@\n+first\n@@ -10,0 +20,1 @@\n+twentieth\n";
        let lines = parse_new_side(diff);
        assert_eq!(lines.first().map(|l| l.new_no), Some(1));
        assert_eq!(lines.last().map(|l| l.new_no), Some(20));
    }
}
