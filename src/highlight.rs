//! Syntax highlighting via `syntect`, themed by the active theme's paired syntax theme.
//!
//! See `specs/diff-view.md` and `specs/theme.md`. The highlighter is rebuilt when the theme
//! changes and produces per-line foreground spans; the pane keeps the terminal's own
//! background, so only token colors come from the theme.

use std::fmt;
use std::io::Cursor;

use syntect::easy::HighlightLines;
use syntect::highlighting::{Theme, ThemeSet};
use syntect::parsing::SyntaxSet;
use syntect::util::LinesWithEndings;

use std::sync::OnceLock;

use crate::diff::{Rgb, Span};
use crate::theme::SyntaxChoice;

/// The default text color when a theme carries none, or its syntax theme fails to load.
const DEFAULT_FG: Rgb = (0xcd, 0xd6, 0xf4);

/// The broad bat/two-face syntax set, built once per process (it is expensive to
/// deserialize) and shared across every `Highlighter`.
fn syntaxes() -> &'static SyntaxSet {
    static SYNTAXES: OnceLock<SyntaxSet> = OnceLock::new();
    SYNTAXES.get_or_init(two_face::syntax::extra_newlines)
}

/// The two-face embedded theme set, deserialized once and shared — like [`syntaxes`], so a
/// theme switch clones one theme out of the cached set instead of rebuilding the whole dump.
fn embedded_themes() -> &'static two_face::theme::EmbeddedLazyThemeSet {
    static THEMES: OnceLock<two_face::theme::EmbeddedLazyThemeSet> = OnceLock::new();
    THEMES.get_or_init(two_face::theme::extra)
}

/// Holds the active syntax theme (absent when it failed to load); highlights file content
/// into spans against the shared syntax set.
pub struct Highlighter {
    theme: Option<Theme>,
    default_fg: Rgb,
}

impl fmt::Debug for Highlighter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Highlighter").finish_non_exhaustive()
    }
}

impl Highlighter {
    /// Build from a theme's paired syntax source: a bundled `.tmTheme` (parsed from vendored
    /// bytes), or a theme from the `two-face` embedded set. A bundled theme that fails to
    /// parse leaves the highlighter theme-less, so highlighting degrades to plain spans
    /// rather than crashing (`specs/theme.md`). Most files color out of the box via the
    /// broad two-face syntax set.
    pub fn new(syntax: SyntaxChoice) -> Self {
        let theme = match syntax {
            SyntaxChoice::Bundled(bytes) => {
                match ThemeSet::load_from_reader(&mut Cursor::new(bytes)) {
                    Ok(theme) => Some(theme),
                    Err(e) => {
                        crate::logln!("bundled syntax theme failed to parse: {e}");
                        None
                    }
                }
            }
            SyntaxChoice::Embedded(name) => Some(embedded_themes().get(name).clone()),
        };
        let default_fg = theme
            .as_ref()
            .and_then(|t| t.settings.foreground)
            .map_or(DEFAULT_FG, |c| (c.r, c.g, c.b));
        Self { theme, default_fg }
    }

    /// Highlight `content` line by line. Each inner `Vec` is one line's spans. With no
    /// known `language` — or no loaded theme — every line is a single plain span in the
    /// default color. `language` matches as an extension first (paths), then as a token
    /// name (markdown fence tags like `rust` or `python`).
    ///
    /// For a C# file the result is then passed through [`inject_sql`](Self::inject_sql), so a
    /// raw string literal holding a SQL query colours with the SQL grammar rather than as flat
    /// string text (specs/diff-view.md).
    pub fn highlight(&self, content: &str, language: Option<&str>) -> Vec<Vec<Span>> {
        let base = self.highlight_base(content, language);
        if is_csharp(language) { self.inject_sql(content, base) } else { base }
    }

    /// The plain single-grammar highlight: `content` tokenized by `language`'s syntax against
    /// the shared set, or one default-colour span per line when the language or theme is
    /// unknown.
    fn highlight_base(&self, content: &str, language: Option<&str>) -> Vec<Vec<Span>> {
        let syntaxes = syntaxes();
        let syntax = language.and_then(|lang| {
            syntaxes.find_syntax_by_extension(lang).or_else(|| syntaxes.find_syntax_by_token(lang))
        });
        let (Some(syntax), Some(theme)) = (syntax, self.theme.as_ref()) else {
            return content
                .lines()
                .map(|l| vec![Span { text: l.to_string(), color: self.default_fg }])
                .collect();
        };
        let mut h = HighlightLines::new(syntax, theme);
        let mut out = Vec::new();
        for line in LinesWithEndings::from(content) {
            let spans = match h.highlight_line(line, syntaxes) {
                Ok(regions) => regions
                    .into_iter()
                    .map(|(style, text)| Span {
                        text: text.trim_end_matches('\n').to_string(),
                        color: (style.foreground.r, style.foreground.g, style.foreground.b),
                    })
                    .collect(),
                // A grammar error degrades to plain text rather than blocking the diff.
                Err(_) => vec![Span {
                    text: line.trim_end_matches('\n').to_string(),
                    color: self.default_fg,
                }],
            };
            out.push(spans);
        }
        out
    }

    /// Overlay SQL highlighting onto the body lines of any C# raw string literal that reads as
    /// SQL — one whose body begins with a SQL keyword, or that carries a `lang=sql` /
    /// `language=sql` marker on or just above its opening. Each such body line is re-tokenized
    /// with the SQL grammar (a contiguous block shares one stateful pass, so multi-line SQL
    /// constructs carry across lines) and its spans replace the flat C# string spans. Lines
    /// outside a SQL body keep their C# highlighting (specs/diff-view.md).
    fn inject_sql(&self, content: &str, mut base: Vec<Vec<Span>>) -> Vec<Vec<Span>> {
        let Some(theme) = self.theme.as_ref() else { return base };
        let syntaxes = syntaxes();
        let Some(sql) = syntaxes.find_syntax_by_token("sql") else { return base };
        let lines: Vec<&str> = content.lines().collect();
        for region in sql_regions(&lines) {
            let mut h = HighlightLines::new(sql, theme);
            for i in region {
                let Some(slot) = base.get_mut(i) else { break };
                let with_nl = format!("{}\n", lines[i]);
                if let Ok(regions) = h.highlight_line(&with_nl, syntaxes) {
                    *slot = regions
                        .into_iter()
                        .map(|(style, text)| Span {
                            text: text.trim_end_matches('\n').to_string(),
                            color: (style.foreground.r, style.foreground.g, style.foreground.b),
                        })
                        .collect();
                }
            }
        }
        base
    }
}

/// The SQL statement keywords that mark a raw-string body as an embedded query, matched
/// case-insensitively against the first non-blank body line.
const SQL_KEYWORDS: &[&str] = &["select", "insert", "update", "delete", "with", "merge"];

/// Whether `language` names C# — the one host grammar the SQL injection runs inside.
fn is_csharp(language: Option<&str>) -> bool {
    matches!(language, Some("cs" | "csx" | "csharp" | "c#"))
}

/// Whether a line carries the ReSharper/Rider embedded-language hint (`lang=sql` or
/// `language=sql`, in any comment form), matched case-insensitively.
fn has_sql_marker(line: &str) -> bool {
    let lower = line.to_ascii_lowercase();
    lower.contains("lang=sql") || lower.contains("language=sql")
}

/// The length of the trailing run of `"` that opens a multi-line raw string literal — a line
/// ending (after trailing whitespace) in three or more double-quotes. `None` when the line
/// does not open a raw string, so a closing line like `""";` (ending in `;`) is never taken
/// for an opening.
fn opening_raw_delim(line: &str) -> Option<usize> {
    let trimmed = line.trim_end();
    let run = trimmed.chars().rev().take_while(|&c| c == '"').count();
    (run >= 3).then_some(run)
}

/// Whether `line` closes a raw string opened with `delim` quotes — it holds a run of at least
/// `delim` consecutive double-quotes (typically `"""` alone or followed by `;`/`,`/`)`).
fn closes_raw(line: &str, delim: usize) -> bool {
    let mut run = 0usize;
    for c in line.chars() {
        if c == '"' {
            run += 1;
            if run >= delim {
                return true;
            }
        } else {
            run = 0;
        }
    }
    false
}

/// Whether the first non-blank line in `body` begins with a SQL statement keyword on a word
/// boundary — the heuristic that a raw string holds a query.
fn body_is_sql(lines: &[&str], body: std::ops::Range<usize>) -> bool {
    for k in body {
        let trimmed = lines[k].trim();
        if trimmed.is_empty() {
            continue;
        }
        let lower = trimmed.to_ascii_lowercase();
        return SQL_KEYWORDS.iter().any(|kw| {
            lower.strip_prefix(kw).is_some_and(|rest| {
                rest.chars().next().is_none_or(|c| !c.is_alphanumeric() && c != '_')
            })
        });
    }
    false
}

/// The body-line ranges of every raw string literal that reads as SQL. A literal qualifies
/// when a `lang=sql` marker sits on or within two lines above its opening, or its body begins
/// with a SQL keyword. Body lines are those strictly between the opening and closing delimiter
/// lines (specs/diff-view.md).
fn sql_regions(lines: &[&str]) -> Vec<std::ops::Range<usize>> {
    let mut regions = Vec::new();
    let mut last_marker: Option<usize> = None;
    let mut i = 0;
    while i < lines.len() {
        if has_sql_marker(lines[i]) {
            last_marker = Some(i);
        }
        if let Some(delim) = opening_raw_delim(lines[i]) {
            let marked = last_marker.is_some_and(|m| i - m <= 2);
            let body_start = i + 1;
            let close = (body_start..lines.len()).find(|&j| closes_raw(lines[j], delim));
            if let Some(end) = close {
                let body = body_start..end;
                if body.start < body.end && (marked || body_is_sql(lines, body.clone())) {
                    regions.push(body);
                }
                last_marker = None;
                i = end + 1;
                continue;
            }
        }
        i += 1;
    }
    regions
}

#[cfg(test)]
mod tests {
    use super::Highlighter;
    use crate::theme;

    /// The bundled Catppuccin Mocha syntax, the default theme's pairing.
    fn mocha() -> super::SyntaxChoice {
        theme::resolve(Some("catppuccin")).syntax
    }

    #[test]
    fn highlights_rust_into_colored_spans() {
        let h = Highlighter::new(mocha());
        let lines = h.highlight("let x = 1;\n", Some("rs"));
        assert_eq!(lines.len(), 1);
        let spans = &lines[0];
        assert!(spans.len() > 1, "rust tokenizes into several spans");
        assert_eq!(spans.iter().map(|s| s.text.as_str()).collect::<String>(), "let x = 1;");
        // The Catppuccin keyword color (mauve) differs from the default text color.
        assert!(spans.iter().any(|s| s.text == "let" && s.color != (0xcd, 0xd6, 0xf4)));
    }

    #[test]
    fn unknown_language_is_one_plain_span_per_line() {
        let h = Highlighter::new(mocha());
        let lines = h.highlight("alpha\nbeta\n", None);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0], vec![super::Span { text: "alpha".into(), color: (0xcd, 0xd6, 0xf4) }]);
    }

    #[test]
    fn bundled_syntax_themes_all_parse() {
        // Each bundled `.tmTheme` must load, or highlighting silently degrades to plain spans
        // (specs/theme.md). A loaded theme tokenizes rust into more than one span; a failed
        // load would yield a single plain span — so this guards the parse path for every
        // bundled theme, the only `SyntaxChoice` that can fail.
        for name in ["catppuccin", "tokyo-night", "tokyo-night-day", "rose-pine", "rose-pine-dawn"]
        {
            let h = Highlighter::new(theme::resolve(Some(name)).syntax);
            let spans = h.highlight("let x = 1;\n", Some("rs"));
            assert!(spans[0].len() > 1, "{name}: bundled syntax theme failed to load");
        }
    }

    /// The colour the SQL grammar gives a statement keyword like `SELECT`, distinct from the
    /// flat string colour C# gives the same text. Taken from a standalone SQL highlight so the
    /// injection assertions compare against the real grammar output, not a hard-coded hue.
    fn sql_keyword_color(h: &Highlighter) -> super::Rgb {
        let line = &h.highlight("SELECT 1\n", Some("sql"))[0];
        line.iter().find(|s| s.text == "SELECT").expect("sql colours SELECT").color
    }

    /// The spans of the line whose text contains `needle`, for scoping an assertion to one
    /// body line rather than the whole file (where `var`/`const` keywords share the SQL
    /// keyword hue).
    fn line_with<'a>(out: &'a [Vec<super::Span>], needle: &str) -> &'a [super::Span] {
        out.iter().find(|l| l.iter().any(|s| s.text.contains(needle))).expect("line present")
    }

    #[test]
    fn sql_injection_colours_a_raw_string_body_that_looks_like_sql() {
        let h = Highlighter::new(mocha());
        let sql = sql_keyword_color(&h);
        // A raw string whose body begins with SELECT — the pling-backend pattern, no marker.
        let src =
            "const string sql =\n    \"\"\"\n        SELECT CaseId\n        FROM T\n    \"\"\";\n";
        let out = h.highlight(src, Some("cs"));
        assert!(
            line_with(&out, "SELECT").iter().any(|s| s.text.trim() == "SELECT" && s.color == sql),
            "SELECT in the body is coloured by the SQL grammar"
        );
        assert!(
            line_with(&out, "FROM").iter().any(|s| s.text.trim() == "FROM" && s.color == sql),
            "FROM in the body is coloured by the SQL grammar"
        );
    }

    #[test]
    fn sql_injection_respects_a_lang_marker_and_leaves_plain_strings_alone() {
        let h = Highlighter::new(mocha());
        let sql = sql_keyword_color(&h);

        // A body that does NOT begin with a SQL keyword still highlights when marked.
        let marked = "// language=sql\nconst string q =\n    \"\"\"\n        exec sp_do @x\n        SELECT 1\n    \"\"\";\n";
        let out = h.highlight(marked, Some("cs"));
        assert!(
            line_with(&out, "SELECT").iter().any(|s| s.text.trim() == "SELECT" && s.color == sql),
            "a lang=sql marker forces SQL highlighting on a body the heuristic would skip"
        );

        // A prose string that happens to live in a raw literal is left as a C# string: its
        // body line carries no SQL-grammar colour.
        let prose = "var msg =\n    \"\"\"\n        Dear user, your order shipped.\n    \"\"\";\n";
        let out = h.highlight(prose, Some("cs"));
        assert!(
            !line_with(&out, "Dear").iter().any(|s| s.color == sql),
            "a non-SQL raw string keeps its C# string colour"
        );
    }

    #[test]
    fn sql_injection_only_runs_inside_csharp() {
        let h = Highlighter::new(mocha());
        let sql = sql_keyword_color(&h);
        // The same raw-string text in a Rust file is not a C# host — no SQL injection.
        let src = "let s =\n    \"\"\"\n        SELECT 1\n    \"\"\";\n";
        let cs = h.highlight(src, Some("cs"));
        let rust = h.highlight(src, Some("rs"));
        assert!(
            line_with(&cs, "SELECT").iter().any(|s| s.text.trim() == "SELECT" && s.color == sql),
            "C# host injects SQL"
        );
        assert!(
            !line_with(&rust, "SELECT").iter().any(|s| s.color == sql),
            "a non-C# file is never SQL-injected"
        );
    }
}
