//! Grapheme-cluster boundary decisions for the print path.
//!
//! `unicode_segmentation` stays the authority for cluster boundaries. This module
//! answers the codepoint pairs that ordinary text produces directly from character
//! properties, and reports [`Join::Unknown`] for any pair that needs a rule it does
//! not model (spacing marks, prepends, Indic conjuncts, and any script it has no
//! table for). The caller must then fall back to exact extended-cluster
//! segmentation, so a `Yes`/`No` answer here can never widen a cluster the real
//! segmentation would split.
//!
//! The tables deliberately cover only ranges whose Unicode properties are stable and
//! common: combining marks, variation selectors, emoji modifiers, tags, Hangul jamo,
//! regional indicators, the pictographic emoji blocks, and the plain letter blocks
//! used by ordinary UI text. Everything else is `Unknown` by design.

use unicode_width::UnicodeWidthChar;
use std::sync::OnceLock;

/// One lazily initialized page per 256 scalars. Pages derive their entries from the
/// original classifiers, so caching cannot introduce a second Unicode property table.
/// The worst case is bounded at 1,114,112 payload bytes; ordinary text touches a few pages.
static PROPERTY_PAGES: [OnceLock<Box<[u8; 256]>>; 0x1100] =
    [const { OnceLock::new() }; 0x1100];

/// Whether a character joins the cluster already in the cell.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Join {
    /// The pair stays in one extended grapheme cluster.
    Yes,
    /// The pair starts a new cluster.
    No,
    /// Needs exact segmentation.
    Unknown,
}

#[cfg(test)]
thread_local! {
    /// Classifications performed on this thread. A run writer that classified each
    /// character twice would show up here as twice the characters it wrote.
    static CLASSIFICATIONS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// Reset the classification counter for a test that is about to measure one run.
#[cfg(test)]
pub(crate) fn reset_classifications_for_test() {
    CLASSIFICATIONS.with(|count| count.set(0));
}

/// Classifications performed since the last reset.
#[cfg(test)]
pub(crate) fn classifications_for_test() -> usize {
    CLASSIFICATIONS.with(std::cell::Cell::get)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
enum Class {
    /// Break on both sides: C0/C1 controls, format characters and separators.
    Control,
    Cr,
    Lf,
    /// `Grapheme_Extend`: joins the cluster before it.
    Extend,
    Zwj,
    HangulL,
    HangulV,
    HangulT,
    HangulLv,
    HangulLvt,
    Regional,
    /// `Extended_Pictographic`.
    Emoji,
    /// Neither extends nor is extended over.
    Plain,
}

/// Classify a character, or `None` when it needs exact segmentation.
fn class_direct(ch: char) -> Option<Class> {
    let code = ch as u32;
    if code < 0x80 {
        return Some(match code {
            0x0d => Class::Cr,
            0x0a => Class::Lf,
            0x00..=0x1f | 0x7f => Class::Control,
            _ => Class::Plain,
        });
    }
    if code == 0x200d {
        return Some(Class::Zwj);
    }
    // © and ® are pictographs inside the Latin-1 letter block, and a soft hyphen there is
    // a format character, so both answer before the ordinary-script table.
    if matches!(code, 0x00a9 | 0x00ae | 0x203c | 0x2049) {
        return Some(Class::Emoji);
    }
    if matches!(code, 0x00ad | 0x200b | 0x200e..=0x200f | 0x2028..=0x202e | 0x2060..=0x206f) {
        return Some(Class::Control);
    }
    if matches!(code, 0x2000..=0x200a | 0x2010..=0x2027 | 0x202f..=0x205f) {
        return Some(Class::Plain);
    }
    // Hot non-ASCII scripts answer before the broad ordinary/mark tables. In particular,
    // Hangul and pictographs must not walk every combining range just to reach their own.
    match code {
        0x1100..=0x115f | 0xa960..=0xa97c => return Some(Class::HangulL),
        0x1160..=0x11a7 | 0xd7b0..=0xd7c6 => return Some(Class::HangulV),
        0x11a8..=0x11ff | 0xd7cb..=0xd7fb => return Some(Class::HangulT),
        0xac00..=0xd7a3 => {
            return Some(if (code - 0xac00).is_multiple_of(28) {
                Class::HangulLv
            } else {
                Class::HangulLvt
            });
        }
        0x3000..=0x3029 | 0x3041..=0x3096 | 0x30a1..=0x30fa | 0x3400..=0x4dbf | 0x4e00..=0x9fff => {
            return Some(Class::Plain);
        }
        0x1f1e6..=0x1f1ff => return Some(Class::Regional),
        0x1f3fb..=0x1f3ff => return Some(Class::Extend),
        0x1f300..=0x1f5ff | 0x1f600..=0x1f64f | 0x1f680..=0x1f6ff | 0x1f900..=0x1f9ff | 0x1fa70..=0x1faff => {
            return Some(Class::Emoji);
        }
        _ => {}
    }
    // Ordinary scripts answer before the mark table. The two tables never overlap, so
    // this order costs the common case one narrower test instead of the wide one.
    if is_plain(code) {
        return Some(Class::Plain);
    }
    if is_extend(code) {
        return Some(Class::Extend);
    }
    // Symbol blocks contain both pictographs and ordinary symbols. Treating all of them as
    // possible pictographs is conservative: their neighbours still break, while a symbol
    // after ZWJ defers to exact segmentation instead of risking a false GB11 answer.
    if matches!(code, 0x2100..=0x2bff) {
        return Some(Class::Emoji);
    }
    None
}

/// `Grapheme_Extend` ranges the print path meets in ordinary text.
fn is_extend(code: u32) -> bool {
    matches!(
        code,
        0x0300..=0x036f
            | 0x0483..=0x0489
            | 0x0591..=0x05bd
            | 0x05bf
            | 0x05c1..=0x05c2
            | 0x05c4..=0x05c5
            | 0x05c7
            | 0x0610..=0x061a
            | 0x064b..=0x065f
            | 0x0670
            | 0x06d6..=0x06dc
            | 0x06df..=0x06e4
            | 0x06e7..=0x06e8
            | 0x06ea..=0x06ed
            | 0x0711
            | 0x0730..=0x074a
            | 0x07a6..=0x07b0
            | 0x07eb..=0x07f3
            | 0x0816..=0x0819
            | 0x081b..=0x0823
            | 0x0825..=0x0827
            | 0x0829..=0x082d
            | 0x0859..=0x085b
            | 0x08d3..=0x08e1
            | 0x08e3..=0x08ff
            | 0x0e31
            | 0x0e34..=0x0e3a
            | 0x0e47..=0x0e4e
            | 0x0eb1
            | 0x0eb4..=0x0ebc
            | 0x0ec8..=0x0ecd
            | 0x0f18..=0x0f19
            | 0x0f35
            | 0x0f37
            | 0x0f39
            | 0x0f71..=0x0f7e
            | 0x0f80..=0x0f84
            | 0x0f86..=0x0f87
            | 0x0f8d..=0x0f97
            | 0x0f99..=0x0fbc
            | 0x0fc6
            | 0x1ab0..=0x1ace
            | 0x1dc0..=0x1dff
            | 0x200c
            | 0x20d0..=0x20f0
            | 0x2cef..=0x2cf1
            | 0x2d7f
            | 0x2de0..=0x2dff
            | 0x302a..=0x302f
            | 0x3099..=0x309a
            | 0xff9e..=0xff9f
            | 0xfe00..=0xfe0f
            | 0xfe20..=0xfe2f
            | 0x1f3fb..=0x1f3ff
            | 0xe0020..=0xe007f
            | 0xe0100..=0xe01ef
    )
}

/// Letter and punctuation blocks with no marks, pictographs or prepends.
fn is_plain(code: u32) -> bool {
    matches!(
        code,
        0x00a0..=0x00ff
            | 0x0100..=0x02ff
            | 0x0370..=0x03ff
            | 0x0400..=0x0482
            | 0x048a..=0x052f
            | 0x1e00..=0x1eff
            | 0x3000..=0x3029
            | 0x3031..=0x3035
            | 0x3041..=0x3096
            | 0x309b..=0x309c
            | 0x30a1..=0x30fa
            | 0x30fc..=0x30ff
            | 0x3400..=0x4dbf
            | 0x4e00..=0x9fff
            | 0xf900..=0xfaff
            | 0xff01..=0xff60
            | 0xff61..=0xff9d
            | 0xffe0..=0xffe6
            | 0x20000..=0x2fa1d
    )
}

/// A character's class, computed once and reused between pair decisions.
///
/// The run writer classifies each character once and carries the answer to the next
/// iteration; [`join_classes`] then decides the pair without classifying either side
/// again.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) struct Classes(u8);

impl Classes {
    const UNKNOWN_CLASS: u8 = 0x0f;
    const UNKNOWN_WIDTH: u8 = 3;

    fn new(class: Option<Class>, width: Option<usize>) -> Self {
        let class = class.map_or(Self::UNKNOWN_CLASS, |class| class as u8);
        let width = width.map_or(Self::UNKNOWN_WIDTH, |width| width.min(2) as u8);
        Self(class | width << 4)
    }
    const fn unknown() -> Self {
        Self(Self::UNKNOWN_CLASS | Self::UNKNOWN_WIDTH << 4)
    }
    const fn class(self) -> Option<Class> {
        match self.0 & 0x0f {
            0 => Some(Class::Control),
            1 => Some(Class::Cr),
            2 => Some(Class::Lf),
            3 => Some(Class::Extend),
            4 => Some(Class::Zwj),
            5 => Some(Class::HangulL),
            6 => Some(Class::HangulV),
            7 => Some(Class::HangulT),
            8 => Some(Class::HangulLv),
            9 => Some(Class::HangulLvt),
            10 => Some(Class::Regional),
            11 => Some(Class::Emoji),
            12 => Some(Class::Plain),
            _ => None,
        }
    }
    /// Width of this scalar outside a cluster; the column clamp stays at the call site.
    pub(crate) fn width(self) -> Option<usize> {
        match self.0 >> 4 {
            0 => Some(0),
            1 => Some(1),
            2 => Some(2),
            _ => None,
        }
    }
}

/// The width of a character that never joins a cluster with a neighbour that is also
/// such a character: printable ASCII, U+00A0..U+02FF without the two pictographs and
/// the soft hyphen, and the kana, CJK ideograph and Hangul syllable blocks. Their
/// classes are plain or a Hangul syllable, and no pair of those joins, so a run of them
/// needs no property lookup or pair decision. Tests check this against the tables.
#[inline]
pub(crate) fn simple_width(ch: char) -> Option<u8> {
    let code = ch as u32;
    // One comparison settles pictographs, flags and everything else above the blocks.
    if code > 0xd7a3 {
        return None;
    }
    if code < 0x300 {
        return match code {
            0x20..=0x7e => Some(1),
            0xa0..=0x2ff if !matches!(code, 0xa9 | 0xad | 0xae) => Some(1),
            _ => None,
        };
    }
    match code {
        0x3041..=0x3096 | 0x30a1..=0x30fa | 0x4e00..=0x9fff | 0xac00..=0xd7a3 => Some(2),
        _ => None,
    }
}

/// Look up both properties once. A page is built only from the existing class function
/// and `UnicodeWidthChar`; `OnceLock` also makes concurrent first use deterministic.
#[inline]
pub(crate) fn classes(ch: char) -> Classes {
    #[cfg(test)]
    CLASSIFICATIONS.with(|count| count.set(count.get() + 1));
    let code = ch as u32;
    if code < 0x80 {
        return Classes::new(class_direct(ch), (!ch.is_ascii_control()).then_some(1));
    }
    let page = (code >> 8) as usize;
    let entries = PROPERTY_PAGES[page].get_or_init(|| {
        let mut entries = Box::new([Classes::unknown().0; 256]);
        for (offset, entry) in entries.iter_mut().enumerate() {
            let code = (page << 8) | offset;
            if let Some(ch) = char::from_u32(code as u32) {
                *entry = Classes::new(class_direct(ch), ch.width()).0;
            }
        }
        entries
    });
    Classes(entries[code as usize & 0xff])
}

fn class(ch: char) -> Option<Class> {
    classes(ch).class()
}

/// Whether `next` stays in the cluster that already ends with the cell content
/// `lead` + `combining`.
pub(crate) fn join(lead: char, combining: &[char], next: char) -> Join {
    let tail = combining.last().copied().unwrap_or(lead);
    join_classes(classes(tail), classes(next), lead, combining)
}

/// [`join`] with both sides already classified.
///
/// `tail` is the class of the last character in the cluster: `combining.last()`, or
/// `lead` when there is none. `lead` and `combining` are still passed because the
/// regional-indicator look-behind has to count the run that ends at the tail.
pub(crate) fn join_classes(tail: Classes, next: Classes, lead: char, combining: &[char]) -> Join {
    match PAIRS[usize::from(tail.0 & 0x0f)][usize::from(next.0 & 0x0f)] {
        Pair::No => Join::No,
        Pair::Yes => Join::Yes,
        Pair::Unknown => Join::Unknown,
        Pair::RegionalRun => {
            if regional_run_is_odd(lead, combining) { Join::Yes } else { Join::No }
        }
    }
}

/// The pair decision for two class nibbles, with the regional-indicator look-behind
/// left to the caller.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Pair {
    No,
    Yes,
    Unknown,
    /// Join exactly when an odd run of regional indicators ends at the tail.
    RegionalRun,
}

/// Every pair of class nibbles (including the unknown class) decided once, at compile
/// time, by [`pair_rule`], so a run decides a pair with one lookup.
const PAIRS: [[Pair; 16]; 16] = {
    let mut table = [[Pair::No; 16]; 16];
    let mut tail = 0;
    while tail < 16 {
        let mut next = 0;
        while next < 16 {
            table[tail][next] = pair_rule(Classes(tail as u8).class(), Classes(next as u8).class());
            next += 1;
        }
        tail += 1;
    }
    table
};

/// The grapheme pair rules over two classes.
const fn pair_rule(tail: Option<Class>, next: Option<Class>) -> Pair {
    let (Some(tail), Some(next)) = (tail, next) else {
        return Pair::Unknown;
    };
    // GB3/GB4/GB5: CR LF stays together; other controls break on both sides.
    if matches!((tail, next), (Class::Cr, Class::Lf)) {
        return Pair::Yes;
    }
    if matches!(tail, Class::Control | Class::Cr | Class::Lf)
        || matches!(next, Class::Control | Class::Cr | Class::Lf)
    {
        return Pair::No;
    }
    // GB9: no break before an extending character or a zero width joiner.
    if matches!(next, Class::Extend | Class::Zwj) {
        return Pair::Yes;
    }
    // GB6/GB7/GB8: Hangul syllable composition.
    if matches!(
        (tail, next),
        (Class::HangulL, Class::HangulL | Class::HangulV | Class::HangulLv | Class::HangulLvt)
            | (Class::HangulLv | Class::HangulV, Class::HangulV | Class::HangulT)
            | (Class::HangulLvt | Class::HangulT, Class::HangulT)
    ) {
        return Pair::Yes;
    }
    // GB11 joins a pictograph only after `pictograph Extend* ZWJ`. Whether the
    // character before the ZWJ is a pictograph is exactly the look-behind this table
    // cannot answer without the full Extended_Pictographic property, so the pair
    // defers to exact segmentation. Every other pictograph neighbour is a break.
    if matches!(next, Class::Emoji) {
        return if matches!(tail, Class::Zwj) { Pair::Unknown } else { Pair::No };
    }
    // GB12/GB13: regional indicators pair up two at a time.
    if matches!((tail, next), (Class::Regional, Class::Regional)) {
        return Pair::RegionalRun;
    }
    Pair::No
}

/// Whether an odd number of regional indicators immediately precede `next`.
fn regional_run_is_odd(lead: char, combining: &[char]) -> bool {
    let mut count = 0usize;
    for &ch in combining.iter().rev().chain(std::iter::once(&lead)) {
        if class(ch) == Some(Class::Regional) {
            count += 1;
        } else {
            break;
        }
    }
    count % 2 == 1
}

#[cfg(test)]
mod tests {
    #[test]
    fn simple_characters_match_the_tables_and_never_join_each_other() {
        // Every simple character has the table's class and width, its class is plain or
        // a Hangul syllable, and every pair of those classes is a break.
        let mut seen = Vec::new();
        for code in 0..=0x10ffffu32 {
            let Some(ch) = char::from_u32(code) else { continue };
            let Some(width) = super::simple_width(ch) else { continue };
            let classes = super::classes(ch);
            assert_eq!(classes.width(), Some(usize::from(width)), "{code:#x}");
            assert_eq!(ch.width(), Some(usize::from(width)), "{code:#x}");
            let class = classes.class();
            assert!(matches!(class, Some(Class::Plain | Class::HangulLv | Class::HangulLvt)), "{code:#x} {class:?}");
            if !seen.iter().any(|(seen, _)| *seen == class) {
                seen.push((class, ch));
            }
        }
        assert_eq!(seen.len(), 3, "plain and both Hangul syllable classes are covered");
        for &(_, tail) in &seen {
            for &(_, next) in &seen {
                let verdict = super::join_classes(super::classes(tail), super::classes(next), tail, &[]);
                assert_eq!(verdict, Join::No, "{tail:?} then {next:?}");
            }
        }
    }
    use super::*;
    use unicode_segmentation::UnicodeSegmentation;

    /// Every scalar value, so the property tables are checked against the real
    /// segmentation for the whole of Unicode and not just the ranges they name.
    fn scalars() -> impl Iterator<Item = char> {
        (0..=0x10ffffu32).filter_map(char::from_u32)
    }

    #[test]
    fn cached_properties_match_the_original_classifiers_over_unicode() {
        for ch in scalars() {
            let cached = classes(ch);
            assert_eq!(cached.class(), class_direct(ch), "class for scalar {:#x}", ch as u32);
            assert_eq!(cached.width(), ch.width().map(|width| width.min(2)), "width for scalar {:#x}", ch as u32);
        }
    }

    #[test]
    fn property_pages_are_safe_during_concurrent_first_use() {
        let chars = ['\u{10ffff}', '\u{e01ef}', '\u{2fa1d}', '😀', '한', '中'];
        std::thread::scope(|scope| {
            for _ in 0..4 {
                scope.spawn(|| {
                    for ch in chars {
                        assert_eq!(classes(ch).class(), class_direct(ch));
                        assert_eq!(classes(ch).width(), ch.width().map(|width| width.min(2)));
                    }
                });
            }
        });
    }

    /// `join` must either agree with exact segmentation or report `Unknown`.
    fn assert_agrees(lead: char, combining: &[char], next: char) {
        let verdict = join(lead, combining, next);
        if verdict == Join::Unknown {
            return;
        }
        let cluster: String = std::iter::once(lead)
            .chain(combining.iter().copied())
            .collect();
        let candidate: String = cluster.chars().chain(std::iter::once(next)).collect();
        let expected = candidate.graphemes(true).count() == cluster.graphemes(true).count();
        assert_eq!(
            expected,
            verdict == Join::Yes,
            "{cluster:?} + {next:?} ({:#x}): fast path said {verdict:?}, exact segmentation split {}",
            next as u32,
            cluster.graphemes(true).count() != candidate.graphemes(true).count(),
        );
    }

    #[test]
    fn pair_decisions_agree_with_exact_segmentation_over_unicode() {
        // Plain text, controls, a combining mark, a ZWJ, a regional indicator and
        // pictographs: every class the fast path answers, and every character as the new one.
        for lead in ['a', '\r', '\n', '\0', '\u{300}', '\u{200d}', '\u{1f1ef}', '\u{1f469}', '中'] {
            for next in scalars() {
                assert_agrees(lead, &[], next);
            }
        }
    }

    #[test]
    fn every_scalar_tail_agrees_with_exact_segmentation() {
        for lead in scalars() {
            for next in ['a', '\n', '\u{301}', '\u{1100}', '\u{1f1ef}', '👩'] {
                assert_agrees(lead, &[], next);
            }
            assert_agrees(lead, &['\u{200d}'], '👩');
        }
    }

    #[test]
    fn contextual_decisions_agree_with_exact_segmentation() {
        // Clusters that end in ZWJ, hold a regional pair, or start with a mark need
        // the look-behind that pair tests cannot reach.
        let clusters = [
            "👩",
            "👩🏽",
            "👩🏽\u{200d}",
            "🇯🇵",
            "🇯",
            "a\u{301}",
            "\u{301}",
            "한",
            "\u{1100}",
            "❤",
            "❤\u{fe0f}",
            "🏳",
            "中\u{301}",
            "1\u{20e3}",
        ];
        for cluster in clusters {
            let chars: Vec<char> = cluster.chars().collect();
            let (lead, combining) = (chars[0], &chars[1..]);
            for next in scalars() {
                assert_agrees(lead, combining, next);
            }
        }
    }

    #[test]
    fn plain_characters_never_join_a_pictograph_after_a_zwj() {
        // `Plain` is the only class the fast path uses to answer "break" right after a
        // ZWJ, which is sound only when no plain character is a pictograph.
        for lead in scalars() {
            if class(lead) != Some(Class::Plain) {
                continue;
            }
            let mut candidate = String::new();
            candidate.push('\u{1f600}');
            candidate.push('\u{200d}');
            candidate.push(lead);
            assert!(
                candidate.graphemes(true).count() > 1,
                "{lead:?} ({:#x}) is classified plain but joins a pictograph after a ZWJ",
                lead as u32,
            );
        }
    }

    #[test]
    fn plain_and_extend_tables_never_overlap() {
        // `class` decides ordinary scripts before extending marks, which is sound only
        // while the two tables stay disjoint for every scalar value.
        for ch in scalars() {
            let code = ch as u32;
            assert!(
                !(is_plain(code) && is_extend(code)),
                "{ch:?} ({code:#x}) is in both the plain and the extend table",
            );
        }
    }

    #[test]
    fn ordinary_script_boundaries_are_decided_without_segmentation() {
        for (lead, next) in [
            ('a', 'b'),
            ('中', '文'),
            ('한', '국'),
            ('é', 'x'),
            ('😀', '😀'),
        ] {
            assert_eq!(join(lead, &[], next), Join::No, "{lead:?} + {next:?}");
        }
        for (lead, next) in [
            ('a', '\u{301}'),
            ('中', '\u{301}'),
            ('😀', '\u{1f3fd}'),
            ('😀', '\u{200d}'),
            ('a', '\u{fe0f}'),
            ('1', '\u{20e3}'),
            ('\u{1100}', '\u{1161}'),
            ('🇯', '🇵'),
        ] {
            assert_eq!(join(lead, &[], next), Join::Yes, "{lead:?} + {next:?}");
        }
        // GB11 needs the full Extended_Pictographic look-behind, so a pictograph right
        // after a ZWJ always defers; the exact fallback keeps that path correct.
        assert_eq!(join('👩', &['\u{1f3fd}', '\u{200d}'], '💻'), Join::Unknown);
        assert_eq!(join('😀', &['\u{200d}'], '💻'), Join::Unknown);
        // Scripts whose rules are not modelled must defer to exact segmentation.
        for (lead, next) in [('\u{915}', '\u{94d}'), ('中', '\u{915}'), ('\u{600}', 'a')] {
            assert_eq!(join(lead, &[], next), Join::Unknown, "{lead:?} + {next:?}");
        }
    }

    /// The carried-class form must decide exactly what the wrapper decides.
    fn assert_classified_agrees(lead: char, combining: &[char], next: char) {
        let tail = combining.last().copied().unwrap_or(lead);
        assert_eq!(
            join_classes(classes(tail), classes(next), lead, combining),
            join(lead, combining, next),
            "{lead:?} + {combining:?} + {next:?}",
        );
    }

    #[test]
    fn carried_class_decisions_match_the_pair_wrapper() {
        // Classified and unclassified pairs must agree for every shape the run path
        // decides: ordinary scripts, unmodelled scripts, marks, joiners, regional
        // indicators and pictographs.
        for lead in [
            'a',
            '\u{300}',
            '\u{200d}',
            '\u{1f1ef}',
            '\u{1f469}',
            '中',
            '\u{915}',
            '\u{600}',
        ] {
            for next in scalars() {
                assert_classified_agrees(lead, &[], next);
            }
        }
        // Clusters that end in ZWJ, hold a regional pair, or start with a mark need the
        // look-behind the carried class cannot see on its own.
        for cluster in [
            "👩🏽\u{200d}",
            "🇯🇵",
            "🇯",
            "a\u{301}",
            "\u{301}",
            "한",
            "❤\u{fe0f}",
            "中\u{301}",
            "1\u{20e3}",
            "\u{915}\u{94d}",
            "\u{600}a",
        ] {
            let chars: Vec<char> = cluster.chars().collect();
            let (lead, combining) = (chars[0], &chars[1..]);
            for next in scalars() {
                assert_classified_agrees(lead, combining, next);
            }
        }
    }

    /// Replay the run writer's carried-class loop: classify each character once, keep
    /// the answer for the next pair decision, and never classify the same side twice.
    fn assert_carried_run_matches(chars: &[char]) {
        let mut previous: Option<(char, Classes)> = None;
        for &next in chars {
            let next_class = classes(next);
            let verdict = match previous {
                Some((lead, tail)) => join_classes(tail, next_class, lead, &[]),
                None => Join::No,
            };
            assert_eq!(
                verdict,
                match previous {
                    Some((lead, _)) => join(lead, &[], next),
                    None => Join::No,
                },
                "carried class diverged at {next:?} in {chars:?}",
            );
            previous = Some((next, next_class));
        }
    }

    #[test]
    fn carried_run_matches_the_wrapper_over_mixed_text() {
        let corpus = [
            "ordinary ascii text",
            "中文字元漢字 한국어 ハングル",
            "\u{915}\u{94d}\u{937} \u{928}\u{92e}\u{938}\u{94d}\u{924}\u{947}",
            "\u{627}\u{644}\u{639}\u{631}\u{628}\u{64a}\u{629} \u{5d0}\u{5d1}\u{5d2}",
            "\u{e01}\u{e33}\u{e49}\u{e32}\u{e19} \u{1780}\u{17d2}\u{1799}\u{17b6}",
            "🇯🇵🇺🇸🇬🇧🇫🇷🇯🇩🇪🇮🇹",
            "👩🏽\u{200d}💻👨\u{200d}👩\u{200d}👧🏳️\u{200d}🌈",
            "e\u{301}\u{302} 중\u{301} 1\u{fe0f}\u{20e3}",
            "\u{600}abc\u{604}xyz",
            "\u{1100}\u{1161}\u{11a8}\u{ac00}\u{11a8}",
            "mix 中👩\u{200d}💻🇯🇵한\u{301} tail",
        ];
        for text in corpus {
            let chars: Vec<char> = text.chars().collect();
            assert_carried_run_matches(&chars);
        }
    }
}
