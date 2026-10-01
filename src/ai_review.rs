//! AI review: hand the open file's diff to the Copilot CLI and turn its findings into
//! in-memory comments on the diff (specs/ai-review.md).
//!
//! Read-only by construction, to honor the **No writes** invariant (specs/overview.md):
//! the engine is launched with no tool permissions, its working directory is an isolated
//! temp dir (never the worktree), and its stdin is closed — so it can neither edit the
//! repository nor block waiting on an approval prompt. The diff travels inline in the
//! prompt; nothing about the repo is reachable through the filesystem.

use std::fmt::Write as _;
use std::process::{Command, Stdio};

use serde::Deserialize;

/// The engine binary. A missing binary surfaces as an `AiOutcome::Error`, never a panic.
const ENGINE: &str = "copilot";

/// Cap the lines fed to the engine, so a huge diff can't build an unbounded prompt. A
/// review past this point is truncated with a trailing marker; the anchored comments still
/// land on the lines that were sent.
const MAX_LINES: usize = 800;

/// One new-side diff line handed to the engine: its line number and marker-prefixed text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiffLine {
    pub new_no: u32,
    /// The line with its `+`/` ` marker, exactly as it reads in the diff.
    pub marker_text: String,
}

/// One finding the engine returned: a new-side line number and the comment text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Finding {
    pub line: u32,
    pub comment: String,
}

/// The result of a review run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AiOutcome {
    Findings(Vec<Finding>),
    Error(String),
}

/// The shape the engine is asked to emit; extra fields are ignored.
#[derive(Deserialize)]
struct RawFinding {
    line: u32,
    comment: String,
}

/// Review one file's diff: build the prompt, run the engine, and parse its findings. Any
/// failure is returned as `AiOutcome::Error` for the caller to report — never a panic.
pub fn review_file(file: &str, lines: &[DiffLine]) -> AiOutcome {
    let prompt = build_prompt(file, lines);
    // An isolated, existing directory: the engine can reach nothing of the worktree here.
    let cwd = std::env::temp_dir();
    let output = Command::new(ENGINE)
        .arg("-p")
        .arg(&prompt)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output();
    let output = match output {
        Ok(o) => o,
        Err(e) => return AiOutcome::Error(format!("AI review: could not run `{ENGINE}`: {e}")),
    };
    if !output.status.success() {
        let err = String::from_utf8_lossy(&output.stderr);
        let detail = err.lines().find(|l| !l.trim().is_empty()).unwrap_or("engine failed");
        return AiOutcome::Error(format!("AI review failed: {}", detail.trim()));
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    match parse_findings(&stdout) {
        Some(findings) => AiOutcome::Findings(findings),
        None => AiOutcome::Error("AI review: could not read the engine's response".to_string()),
    }
}

/// The reviewer prompt: the diff inline, each line numbered, and a strict JSON contract.
fn build_prompt(file: &str, lines: &[DiffLine]) -> String {
    let mut body = String::new();
    for line in lines.iter().take(MAX_LINES) {
        let _ = writeln!(body, "{}\t{}", line.new_no, line.marker_text);
    }
    if lines.len() > MAX_LINES {
        body.push_str("… (diff truncated)\n");
    }
    format!(
        "You are a terse, high-signal code reviewer. Review this diff of `{file}`.\n\
         Report only real problems: bugs, logic errors, security issues, resource leaks, \
         missing error handling, and broken edge cases. Do not comment on style, formatting, \
         or naming. Every listed line begins with its line number followed by a tab.\n\
         Respond with ONLY a JSON array and nothing else — no prose, no code fences. Each \
         item is {{\"line\": <one of the listed line numbers>, \"comment\": \"<one short \
         sentence>\"}}. Reference only line numbers that appear below. Return an empty array \
         [] if there is nothing worth flagging.\n\n\
         {body}"
    )
}

/// Extract the JSON array from the engine's reply, tolerating any wrapping prose or code
/// fence, and parse it. `None` when no array parses.
fn parse_findings(text: &str) -> Option<Vec<Finding>> {
    let start = text.find('[')?;
    let end = text.rfind(']')?;
    if end < start {
        return None;
    }
    let raw: Vec<RawFinding> = serde_json::from_str(&text[start..=end]).ok()?;
    Some(
        raw.into_iter()
            .filter(|f| !f.comment.trim().is_empty())
            .map(|f| Finding { line: f.line, comment: f.comment.trim().to_string() })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::{Finding, build_prompt, parse_findings};

    #[test]
    fn parses_a_bare_array() {
        let out = r#"[{"line": 12, "comment": "off-by-one"}]"#;
        assert_eq!(
            parse_findings(out),
            Some(vec![Finding { line: 12, comment: "off-by-one".into() }])
        );
    }

    #[test]
    fn tolerates_wrapping_prose_and_fences() {
        let out = "Here are my findings:\n```json\n[{\"line\": 3, \"comment\": \"leaks the file\"}]\n```\nDone.";
        assert_eq!(
            parse_findings(out),
            Some(vec![Finding { line: 3, comment: "leaks the file".into() }])
        );
    }

    #[test]
    fn empty_array_is_no_findings() {
        assert_eq!(parse_findings("[]"), Some(vec![]));
    }

    #[test]
    fn drops_blank_comments_and_trims() {
        let out = r#"[{"line": 1, "comment": "  keep  "}, {"line": 2, "comment": "   "}]"#;
        assert_eq!(parse_findings(out), Some(vec![Finding { line: 1, comment: "keep".into() }]));
    }

    #[test]
    fn no_array_is_none() {
        assert_eq!(parse_findings("the model refused"), None);
    }

    #[test]
    fn prompt_numbers_lines_and_names_the_file() {
        use super::DiffLine;
        let lines = vec![DiffLine { new_no: 41, marker_text: "+let x = foo();".into() }];
        let p = build_prompt("src/x.rs", &lines);
        assert!(p.contains("src/x.rs"));
        assert!(p.contains("41\t+let x = foo();"));
        assert!(p.contains("JSON array"));
    }
}
