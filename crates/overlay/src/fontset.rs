//! Which font files the overlay draws with. The game's own fonts come first; the Windows font
//! folder supplies one sans-serif and one monospace fallback. A Windows install always has Segoe UI
//! and Consolas, but a Wine or `CrossOver` prefix may have neither (it often has Arial and Courier
//! New), so each fallback is the first readable of a short list, and every family ends up with a
//! font whenever any font could be read at all.
//!
//! Every file is checked with the parser epaint uses (`skrifa::FontRef::from_index`, index 0) before
//! it is handed to egui: epaint panics on a font it cannot parse, and a panic in the overlay ends
//! the game.

/// Sans-serif fallbacks in the Windows font folder, best first: `(name, file)`.
pub(crate) const SANS: &[(&str, &str)] = &[("segoe", "segoeui.ttf"), ("arial", "arial.ttf"), ("tahoma", "tahoma.ttf")];

/// Monospace candidates in the Windows font folder, best first: `(name, file)`.
pub(crate) const MONO: &[(&str, &str)] =
    &[("consolas", "consola.ttf"), ("courier", "cour.ttf"), ("andale", "AndaleMo.TTF"), ("lucida", "lucon.ttf")];

/// Whether epaint can draw with `bytes`: the same parse it does when the font is added.
pub(crate) fn parses(bytes: &[u8]) -> bool {
    skrifa::FontRef::from_index(bytes, 0).is_ok()
}

/// The first candidate whose file `read` returns and `valid` accepts, with its bytes.
pub(crate) fn first_valid<'a>(
    candidates: &[(&'a str, &'a str)],
    read: impl Fn(&str) -> Option<Vec<u8>>,
    valid: impl Fn(&[u8]) -> bool,
) -> Option<(&'a str, &'a str, Vec<u8>)> {
    candidates.iter().find_map(|&(name, file)| read(file).filter(|b| valid(b)).map(|b| (name, file, b)))
}

/// The font names of each family, from the fonts that were loaded: proportional, heading,
/// monospace. `None` when no font was loaded at all.
///
/// - proportional: the game's body font, then the sans fallback, then the monospace font
/// - heading: the game's heading font, then the sans fallback, then the monospace font
/// - monospace: the monospace font, then the sans fallback, then the game's body font
///
/// A family whose first choice is missing falls back on the others, so none is empty when any font
/// was loaded (an empty family draws every glyph as a box).
pub(crate) fn families(
    body: Option<&str>,
    heading: Option<&str>,
    sans: Option<&str>,
    mono: Option<&str>,
) -> Option<[Vec<String>; 3]> {
    let pick = |order: [Option<&str>; 4]| -> Vec<String> {
        let mut names: Vec<String> = Vec::new();
        for name in order.into_iter().flatten() {
            if !names.iter().any(|n| n == name) {
                names.push(name.to_owned());
            }
        }
        names
    };
    let proportional = pick([body, sans, mono, heading]);
    if proportional.is_empty() {
        return None;
    }
    Some([proportional, pick([heading, sans, mono, body]), pick([mono, sans, body, heading])])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reader(files: &'static [(&'static str, &'static [u8])]) -> impl Fn(&str) -> Option<Vec<u8>> {
        move |file| files.iter().find(|(f, _)| *f == file).map(|(_, b)| b.to_vec())
    }

    fn good(bytes: &[u8]) -> bool {
        bytes.starts_with(b"ok")
    }

    #[test]
    fn windows_keeps_consolas_and_segoe() {
        let read = reader(&[("segoeui.ttf", b"ok-segoe"), ("consola.ttf", b"ok-consolas"), ("cour.ttf", b"ok-courier")]);
        assert_eq!(first_valid(SANS, &read, good).map(|f| f.0), Some("segoe"));
        assert_eq!(first_valid(MONO, &read, good).map(|f| f.0), Some("consolas"));
    }

    #[test]
    fn crossover_prefix_takes_arial_and_courier() {
        let read = reader(&[("arial.ttf", b"ok-arial"), ("cour.ttf", b"ok-courier"), ("AndaleMo.TTF", b"ok-andale")]);
        assert_eq!(first_valid(SANS, &read, good).map(|f| f.0), Some("arial"));
        assert_eq!(first_valid(MONO, &read, good).map(|f| f.0), Some("courier"));
    }

    #[test]
    fn an_unparsable_file_is_skipped() {
        let read = reader(&[("consola.ttf", b"garbage"), ("cour.ttf", b"\0\x01"), ("AndaleMo.TTF", b"ok-andale")]);
        assert_eq!(first_valid(MONO, &read, good).map(|f| f.1), Some("AndaleMo.TTF"));
        let none = reader(&[("consola.ttf", b"garbage")]);
        assert!(first_valid(MONO, &none, good).is_none());
    }

    #[test]
    fn real_parser_rejects_garbage_and_truncation() {
        assert!(!parses(b""));
        assert!(!parses(b"not a font at all"));
        assert!(!parses(&[0, 1, 0, 0, 0, 5]));
    }

    #[test]
    fn windows_families_keep_their_order() {
        let [p, h, m] = families(Some("body"), Some("heading"), Some("segoe"), Some("consolas")).unwrap();
        assert_eq!(p, ["body", "segoe", "consolas", "heading"]);
        assert_eq!(h, ["heading", "segoe", "consolas", "body"]);
        assert_eq!(m, ["consolas", "segoe", "body", "heading"]);
    }

    #[test]
    fn no_monospace_font_falls_back_instead_of_staying_empty() {
        let [p, _, m] = families(Some("body"), Some("heading"), None, None).unwrap();
        assert_eq!(p[0], "body");
        assert_eq!(m, ["body", "heading"]);
    }

    #[test]
    fn no_game_font_uses_the_windows_fonts() {
        let [p, h, m] = families(None, None, Some("arial"), Some("courier")).unwrap();
        assert_eq!(p, ["arial", "courier"]);
        assert_eq!(h, ["arial", "courier"]);
        assert_eq!(m, ["courier", "arial"]);
    }

    #[test]
    fn nothing_loaded_is_none() {
        assert!(families(None, None, None, None).is_none());
    }
}
