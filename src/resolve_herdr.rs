//! The `resolve-herdr` subcommand: mark one or more AI-review comments resolved, so a running
//! reviewr pane drops them from its list (specs/ai-review.md).
//!
//! An address prompt (`a` in the pane) hands the agent a comment's id and asks it to run
//! `herdr-reviewr resolve-herdr <id>` once the fix is in. That call lands here: it appends the
//! ids to the worktree's resolve inbox for the pane to pick up on its next poll. Like
//! `review-herdr`, this is a transient, non-UI process that never writes to the repository —
//! the only output is the temp-dir resolve inbox.

use std::path::Path;

use anyhow::{Result, bail};

/// Append `ids` to the worktree resolve inbox. Returns the count handed off. An empty id list
/// is a usage error, not a silent no-op, so a mistyped call is visible rather than pretending
/// to resolve nothing.
pub fn run(repo: &Path, ids: &[u64]) -> Result<usize> {
    if ids.is_empty() {
        bail!("resolve-herdr: expected one or more comment ids");
    }
    crate::ai_resolve::append(repo, ids)?;
    Ok(ids.len())
}

/// Parse the subcommand's id arguments (everything after `resolve-herdr`). A non-numeric or
/// empty argument is rejected with the offending token named, so the agent gets a clear error
/// instead of a swallowed id.
pub fn parse_ids<I, S>(args: I) -> Result<Vec<u64>>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    args.into_iter()
        .map(|a| {
            let a = a.as_ref();
            a.parse::<u64>().map_err(|_| anyhow::anyhow!("resolve-herdr: not a comment id: {a}"))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{parse_ids, run};

    #[test]
    fn parses_a_list_of_ids_and_rejects_a_non_number() {
        assert_eq!(parse_ids(["1", "2", "40"]).unwrap(), vec![1, 2, 40]);
        assert!(parse_ids(["3", "x"]).is_err());
    }

    #[test]
    fn run_appends_the_ids_and_refuses_an_empty_list() {
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path();
        assert!(run(repo, &[]).is_err(), "an empty id list is a usage error");
        assert_eq!(run(repo, &[4, 9]).unwrap(), 2);
        let mut ids = crate::ai_resolve::take(repo).unwrap();
        ids.sort_unstable();
        assert_eq!(ids, vec![4, 9], "the ids reached the resolve inbox");
    }
}
