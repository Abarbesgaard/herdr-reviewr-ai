fn main() -> anyhow::Result<()> {
    // Recognized anywhere in argv, matching the actions' pane-identity read: a process
    // invoked with this flag never counts as the review UI, so it must never run the
    // review UI either (`specs/herdr-host.md` Pane identity). This dispatch and the jq
    // exclusion in `herdr/pane.sh` (`is_reviewr_pane`) are the two halves of that
    // contract — a future non-UI flag must land in both, or the actions will count its
    // transient process as a live reviewr pane.
    if std::env::args_os().skip(1).any(|arg| arg == "--resolve-plugin-config") {
        if let Err(error) = herdr_reviewr::config::print_plugin_config() {
            eprintln!("reviewr: {error}");
            std::process::exit(1);
        }
        return Ok(());
    }
    // The `review-herdr` subcommand is likewise a transient, non-UI process (it reviews the
    // uncommitted changeset and drops comments into the inbox for a running pane to show).
    // It is excluded from pane identity in `herdr/pane.sh` for the same reason as above
    // (specs/ai-review.md).
    if std::env::args_os().nth(1).is_some_and(|arg| arg == "review-herdr") {
        return run_review_herdr();
    }
    // `resolve-herdr <id>...` is the return leg: it marks reviewed comments fixed so a running
    // pane drops them. Like `review-herdr` it is a transient, non-UI process, excluded from
    // pane identity in `herdr/pane.sh` (specs/ai-review.md).
    if std::env::args_os().nth(1).is_some_and(|arg| arg == "resolve-herdr") {
        return run_resolve_herdr();
    }
    herdr_reviewr::run()
}

/// Run the AI review of the uncommitted changeset from the current directory and print a
/// one-line summary. Findings land in the worktree inbox for an open reviewr pane
/// (specs/ai-review.md).
fn run_review_herdr() -> anyhow::Result<()> {
    let cwd = std::env::current_dir()?;
    let repo = herdr_reviewr::git::toplevel(&cwd)
        .ok_or_else(|| anyhow::anyhow!("review-herdr: not inside a git repository"))?;
    let summary = herdr_reviewr::review_herdr::run(&repo)?;
    for err in &summary.errors {
        eprintln!("reviewr: {err}");
    }
    println!(
        "AI review: {} comment{} across {} file{}.",
        summary.comments,
        if summary.comments == 1 { "" } else { "s" },
        summary.files_reviewed,
        if summary.files_reviewed == 1 { "" } else { "s" },
    );
    if summary.comments > 0 {
        println!("Open the reviewr pane to see them inline.");
    }
    Ok(())
}

/// Mark one or more AI-review comments resolved: append their ids to the worktree resolve
/// inbox so an open reviewr pane drops them on its next poll (specs/ai-review.md). The ids come
/// from the address prompt the pane drafted (`resolve-herdr <id>...`).
fn run_resolve_herdr() -> anyhow::Result<()> {
    let cwd = std::env::current_dir()?;
    let repo = herdr_reviewr::git::toplevel(&cwd)
        .ok_or_else(|| anyhow::anyhow!("resolve-herdr: not inside a git repository"))?;
    // Skip argv[0] and the `resolve-herdr` token; the rest are comment ids.
    let ids = herdr_reviewr::resolve_herdr::parse_ids(std::env::args().skip(2))?;
    let n = herdr_reviewr::resolve_herdr::run(&repo, &ids)?;
    println!("Resolved {n} comment{}.", if n == 1 { "" } else { "s" });
    Ok(())
}
