use crate::bounded::{BoundedVec, Span, count_of};
use crate::scan::line_break_width;
use crate::token::{Punctuation, Token, TokenKind};

const NEAR_BREAK_MAX: usize = 8;

pub(crate) const fn punctuated(kind: TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::BlockEnd | TokenKind::BlockStart | TokenKind::Punctuation(_)
    )
}

pub fn substituting(source: &[u8], token: Token) -> bool {
    token.kind == TokenKind::String && token.text(source) == b"${"
}

pub(crate) fn simple_word(token: Token, source: &[u8]) -> bool {
    if matches!(
        token.kind,
        TokenKind::Identifier | TokenKind::Newline | TokenKind::Number | TokenKind::String
    ) {
        return true;
    }

    matches!(
        token.text(source),
        b"!" | b"&" | b"*" | b"-" | b"." | b"?" | b"[" | b"]" | b"as" | b"mut" | b"self"
    )
}

pub(crate) fn columns(source: &[u8], from: u32, to: u32) -> u32 {
    let stop = (to as usize).min(source.len());
    let start = (from as usize).min(stop);

    if source[start..stop].is_ascii() {
        return count_of(stop - start);
    }

    let mut held = 0_u32;
    let mut scan = from as usize;

    while scan < to as usize && scan < source.len() {
        if source[scan] & 0xC0 != 0x80 {
            let point = point_at(source, scan);

            if !marked_at(point) {
                held += if wide_at(source, scan) { 2 } else { 1 };
            }
        }

        scan += 1;
    }

    held
}

pub(crate) const MARK_RANGES: [(u32, u32); 353] = [
    (0x0300, 0x036F),
    (0x0483, 0x0489),
    (0x0591, 0x05BD),
    (0x05BF, 0x05BF),
    (0x05C1, 0x05C2),
    (0x05C4, 0x05C5),
    (0x05C7, 0x05C7),
    (0x0600, 0x0605),
    (0x0610, 0x061A),
    (0x061C, 0x061C),
    (0x064B, 0x065F),
    (0x0670, 0x0670),
    (0x06D6, 0x06DD),
    (0x06DF, 0x06E4),
    (0x06E7, 0x06E8),
    (0x06EA, 0x06ED),
    (0x070F, 0x070F),
    (0x0711, 0x0711),
    (0x0730, 0x074A),
    (0x07A6, 0x07B0),
    (0x07EB, 0x07F3),
    (0x07FD, 0x07FD),
    (0x0816, 0x0819),
    (0x081B, 0x0823),
    (0x0825, 0x0827),
    (0x0829, 0x082D),
    (0x0859, 0x085B),
    (0x0890, 0x0891),
    (0x0898, 0x089F),
    (0x08CA, 0x0902),
    (0x093A, 0x093A),
    (0x093C, 0x093C),
    (0x0941, 0x0948),
    (0x094D, 0x094D),
    (0x0951, 0x0957),
    (0x0962, 0x0963),
    (0x0981, 0x0981),
    (0x09BC, 0x09BC),
    (0x09C1, 0x09C4),
    (0x09CD, 0x09CD),
    (0x09E2, 0x09E3),
    (0x09FE, 0x09FE),
    (0x0A01, 0x0A02),
    (0x0A3C, 0x0A3C),
    (0x0A41, 0x0A42),
    (0x0A47, 0x0A48),
    (0x0A4B, 0x0A4D),
    (0x0A51, 0x0A51),
    (0x0A70, 0x0A71),
    (0x0A75, 0x0A75),
    (0x0A81, 0x0A82),
    (0x0ABC, 0x0ABC),
    (0x0AC1, 0x0AC5),
    (0x0AC7, 0x0AC8),
    (0x0ACD, 0x0ACD),
    (0x0AE2, 0x0AE3),
    (0x0AFA, 0x0AFF),
    (0x0B01, 0x0B01),
    (0x0B3C, 0x0B3C),
    (0x0B3F, 0x0B3F),
    (0x0B41, 0x0B44),
    (0x0B4D, 0x0B4D),
    (0x0B55, 0x0B56),
    (0x0B62, 0x0B63),
    (0x0B82, 0x0B82),
    (0x0BC0, 0x0BC0),
    (0x0BCD, 0x0BCD),
    (0x0C00, 0x0C00),
    (0x0C04, 0x0C04),
    (0x0C3C, 0x0C3C),
    (0x0C3E, 0x0C40),
    (0x0C46, 0x0C48),
    (0x0C4A, 0x0C4D),
    (0x0C55, 0x0C56),
    (0x0C62, 0x0C63),
    (0x0C81, 0x0C81),
    (0x0CBC, 0x0CBC),
    (0x0CBF, 0x0CBF),
    (0x0CC6, 0x0CC6),
    (0x0CCC, 0x0CCD),
    (0x0CE2, 0x0CE3),
    (0x0D00, 0x0D01),
    (0x0D3B, 0x0D3C),
    (0x0D41, 0x0D44),
    (0x0D4D, 0x0D4D),
    (0x0D62, 0x0D63),
    (0x0D81, 0x0D81),
    (0x0DCA, 0x0DCA),
    (0x0DD2, 0x0DD4),
    (0x0DD6, 0x0DD6),
    (0x0E31, 0x0E31),
    (0x0E34, 0x0E3A),
    (0x0E47, 0x0E4E),
    (0x0EB1, 0x0EB1),
    (0x0EB4, 0x0EBC),
    (0x0EC8, 0x0ECE),
    (0x0F18, 0x0F19),
    (0x0F35, 0x0F35),
    (0x0F37, 0x0F37),
    (0x0F39, 0x0F39),
    (0x0F71, 0x0F7E),
    (0x0F80, 0x0F84),
    (0x0F86, 0x0F87),
    (0x0F8D, 0x0F97),
    (0x0F99, 0x0FBC),
    (0x0FC6, 0x0FC6),
    (0x102D, 0x1030),
    (0x1032, 0x1037),
    (0x1039, 0x103A),
    (0x103D, 0x103E),
    (0x1058, 0x1059),
    (0x105E, 0x1060),
    (0x1071, 0x1074),
    (0x1082, 0x1082),
    (0x1085, 0x1086),
    (0x108D, 0x108D),
    (0x109D, 0x109D),
    (0x135D, 0x135F),
    (0x1712, 0x1714),
    (0x1732, 0x1733),
    (0x1752, 0x1753),
    (0x1772, 0x1773),
    (0x17B4, 0x17B5),
    (0x17B7, 0x17BD),
    (0x17C6, 0x17C6),
    (0x17C9, 0x17D3),
    (0x17DD, 0x17DD),
    (0x180B, 0x180F),
    (0x1885, 0x1886),
    (0x18A9, 0x18A9),
    (0x1920, 0x1922),
    (0x1927, 0x1928),
    (0x1932, 0x1932),
    (0x1939, 0x193B),
    (0x1A17, 0x1A18),
    (0x1A1B, 0x1A1B),
    (0x1A56, 0x1A56),
    (0x1A58, 0x1A5E),
    (0x1A60, 0x1A60),
    (0x1A62, 0x1A62),
    (0x1A65, 0x1A6C),
    (0x1A73, 0x1A7C),
    (0x1A7F, 0x1A7F),
    (0x1AB0, 0x1ACE),
    (0x1B00, 0x1B03),
    (0x1B34, 0x1B34),
    (0x1B36, 0x1B3A),
    (0x1B3C, 0x1B3C),
    (0x1B42, 0x1B42),
    (0x1B6B, 0x1B73),
    (0x1B80, 0x1B81),
    (0x1BA2, 0x1BA5),
    (0x1BA8, 0x1BA9),
    (0x1BAB, 0x1BAD),
    (0x1BE6, 0x1BE6),
    (0x1BE8, 0x1BE9),
    (0x1BED, 0x1BED),
    (0x1BEF, 0x1BF1),
    (0x1C2C, 0x1C33),
    (0x1C36, 0x1C37),
    (0x1CD0, 0x1CD2),
    (0x1CD4, 0x1CE0),
    (0x1CE2, 0x1CE8),
    (0x1CED, 0x1CED),
    (0x1CF4, 0x1CF4),
    (0x1CF8, 0x1CF9),
    (0x1DC0, 0x1DFF),
    (0x200B, 0x200F),
    (0x202A, 0x202E),
    (0x2060, 0x2064),
    (0x2066, 0x206F),
    (0x20D0, 0x20F0),
    (0x2CEF, 0x2CF1),
    (0x2D7F, 0x2D7F),
    (0x2DE0, 0x2DFF),
    (0x302A, 0x302D),
    (0x3099, 0x309A),
    (0xA66F, 0xA672),
    (0xA674, 0xA67D),
    (0xA69E, 0xA69F),
    (0xA6F0, 0xA6F1),
    (0xA802, 0xA802),
    (0xA806, 0xA806),
    (0xA80B, 0xA80B),
    (0xA825, 0xA826),
    (0xA82C, 0xA82C),
    (0xA8C4, 0xA8C5),
    (0xA8E0, 0xA8F1),
    (0xA8FF, 0xA8FF),
    (0xA926, 0xA92D),
    (0xA947, 0xA951),
    (0xA980, 0xA982),
    (0xA9B3, 0xA9B3),
    (0xA9B6, 0xA9B9),
    (0xA9BC, 0xA9BD),
    (0xA9E5, 0xA9E5),
    (0xAA29, 0xAA2E),
    (0xAA31, 0xAA32),
    (0xAA35, 0xAA36),
    (0xAA43, 0xAA43),
    (0xAA4C, 0xAA4C),
    (0xAA7C, 0xAA7C),
    (0xAAB0, 0xAAB0),
    (0xAAB2, 0xAAB4),
    (0xAAB7, 0xAAB8),
    (0xAABE, 0xAABF),
    (0xAAC1, 0xAAC1),
    (0xAAEC, 0xAAED),
    (0xAAF6, 0xAAF6),
    (0xABE5, 0xABE5),
    (0xABE8, 0xABE8),
    (0xABED, 0xABED),
    (0xFB1E, 0xFB1E),
    (0xFE00, 0xFE0F),
    (0xFE20, 0xFE2F),
    (0xFEFF, 0xFEFF),
    (0xFFF9, 0xFFFB),
    (0x101FD, 0x101FD),
    (0x102E0, 0x102E0),
    (0x10376, 0x1037A),
    (0x10A01, 0x10A03),
    (0x10A05, 0x10A06),
    (0x10A0C, 0x10A0F),
    (0x10A38, 0x10A3A),
    (0x10A3F, 0x10A3F),
    (0x10AE5, 0x10AE6),
    (0x10D24, 0x10D27),
    (0x10EAB, 0x10EAC),
    (0x10EFD, 0x10EFF),
    (0x10F46, 0x10F50),
    (0x10F82, 0x10F85),
    (0x11001, 0x11001),
    (0x11038, 0x11046),
    (0x11070, 0x11070),
    (0x11073, 0x11074),
    (0x1107F, 0x11081),
    (0x110B3, 0x110B6),
    (0x110B9, 0x110BA),
    (0x110BD, 0x110BD),
    (0x110C2, 0x110C2),
    (0x110CD, 0x110CD),
    (0x11100, 0x11102),
    (0x11127, 0x1112B),
    (0x1112D, 0x11134),
    (0x11173, 0x11173),
    (0x11180, 0x11181),
    (0x111B6, 0x111BE),
    (0x111C9, 0x111CC),
    (0x111CF, 0x111CF),
    (0x1122F, 0x11231),
    (0x11234, 0x11234),
    (0x11236, 0x11237),
    (0x1123E, 0x1123E),
    (0x11241, 0x11241),
    (0x112DF, 0x112DF),
    (0x112E3, 0x112EA),
    (0x11300, 0x11301),
    (0x1133B, 0x1133C),
    (0x11340, 0x11340),
    (0x11366, 0x1136C),
    (0x11370, 0x11374),
    (0x11438, 0x1143F),
    (0x11442, 0x11444),
    (0x11446, 0x11446),
    (0x1145E, 0x1145E),
    (0x114B3, 0x114B8),
    (0x114BA, 0x114BA),
    (0x114BF, 0x114C0),
    (0x114C2, 0x114C3),
    (0x115B2, 0x115B5),
    (0x115BC, 0x115BD),
    (0x115BF, 0x115C0),
    (0x115DC, 0x115DD),
    (0x11633, 0x1163A),
    (0x1163D, 0x1163D),
    (0x1163F, 0x11640),
    (0x116AB, 0x116AB),
    (0x116AD, 0x116AD),
    (0x116B0, 0x116B5),
    (0x116B7, 0x116B7),
    (0x1171D, 0x1171F),
    (0x11722, 0x11725),
    (0x11727, 0x1172B),
    (0x1182F, 0x11837),
    (0x11839, 0x1183A),
    (0x1193B, 0x1193C),
    (0x1193E, 0x1193E),
    (0x11943, 0x11943),
    (0x119D4, 0x119D7),
    (0x119DA, 0x119DB),
    (0x119E0, 0x119E0),
    (0x11A01, 0x11A0A),
    (0x11A33, 0x11A38),
    (0x11A3B, 0x11A3E),
    (0x11A47, 0x11A47),
    (0x11A51, 0x11A56),
    (0x11A59, 0x11A5B),
    (0x11A8A, 0x11A96),
    (0x11A98, 0x11A99),
    (0x11C30, 0x11C36),
    (0x11C38, 0x11C3D),
    (0x11C3F, 0x11C3F),
    (0x11C92, 0x11CA7),
    (0x11CAA, 0x11CB0),
    (0x11CB2, 0x11CB3),
    (0x11CB5, 0x11CB6),
    (0x11D31, 0x11D36),
    (0x11D3A, 0x11D3A),
    (0x11D3C, 0x11D3D),
    (0x11D3F, 0x11D45),
    (0x11D47, 0x11D47),
    (0x11D90, 0x11D91),
    (0x11D95, 0x11D95),
    (0x11D97, 0x11D97),
    (0x11EF3, 0x11EF4),
    (0x11F00, 0x11F01),
    (0x11F36, 0x11F3A),
    (0x11F40, 0x11F40),
    (0x11F42, 0x11F42),
    (0x13430, 0x13440),
    (0x13447, 0x13455),
    (0x16AF0, 0x16AF4),
    (0x16B30, 0x16B36),
    (0x16F4F, 0x16F4F),
    (0x16F8F, 0x16F92),
    (0x16FE4, 0x16FE4),
    (0x1BC9D, 0x1BC9E),
    (0x1BCA0, 0x1BCA3),
    (0x1CF00, 0x1CF2D),
    (0x1CF30, 0x1CF46),
    (0x1D167, 0x1D169),
    (0x1D173, 0x1D182),
    (0x1D185, 0x1D18B),
    (0x1D1AA, 0x1D1AD),
    (0x1D242, 0x1D244),
    (0x1DA00, 0x1DA36),
    (0x1DA3B, 0x1DA6C),
    (0x1DA75, 0x1DA75),
    (0x1DA84, 0x1DA84),
    (0x1DA9B, 0x1DA9F),
    (0x1DAA1, 0x1DAAF),
    (0x1E000, 0x1E006),
    (0x1E008, 0x1E018),
    (0x1E01B, 0x1E021),
    (0x1E023, 0x1E024),
    (0x1E026, 0x1E02A),
    (0x1E08F, 0x1E08F),
    (0x1E130, 0x1E136),
    (0x1E2AE, 0x1E2AE),
    (0x1E2EC, 0x1E2EF),
    (0x1E4EC, 0x1E4EF),
    (0x1E8D0, 0x1E8D6),
    (0x1E944, 0x1E94A),
];

fn marked_at(point: u32) -> bool {
    MARK_RANGES
        .iter()
        .any(|(from, to)| point >= *from && point <= *to)
}

fn point_at(source: &[u8], position: usize) -> u32 {
    let lead = source[position];

    if lead & 0xF0 == 0xE0 {
        if position + 2 >= source.len() {
            return 0;
        }

        return (u32::from(lead & 0x0F) << 12)
            | (u32::from(source[position + 1] & 0x3F) << 6)
            | u32::from(source[position + 2] & 0x3F);
    }

    if lead & 0xF8 == 0xF0 {
        if position + 3 >= source.len() {
            return 0;
        }

        return (u32::from(lead & 0x07) << 18)
            | (u32::from(source[position + 1] & 0x3F) << 12)
            | (u32::from(source[position + 2] & 0x3F) << 6)
            | u32::from(source[position + 3] & 0x3F);
    }

    if lead & 0xE0 == 0xC0 {
        if position + 1 >= source.len() {
            return 0;
        }

        return (u32::from(lead & 0x1F) << 6) | u32::from(source[position + 1] & 0x3F);
    }

    u32::from(lead)
}

fn wide_at(source: &[u8], position: usize) -> bool {
    let lead = source[position];

    let point = if lead & 0xF0 == 0xE0 {
        if position + 2 >= source.len() {
            return false;
        }

        (u32::from(lead & 0x0F) << 12)
            | (u32::from(source[position + 1] & 0x3F) << 6)
            | u32::from(source[position + 2] & 0x3F)
    } else if lead & 0xF8 == 0xF0 {
        if position + 3 >= source.len() {
            return false;
        }

        (u32::from(lead & 0x07) << 18)
            | (u32::from(source[position + 1] & 0x3F) << 12)
            | (u32::from(source[position + 2] & 0x3F) << 6)
            | u32::from(source[position + 3] & 0x3F)
    } else {
        return false;
    };

    matches!(
        point,
        0x1100..=0x115F
            | 0x2E80..=0x303E
            | 0x3041..=0x33FF
            | 0x3400..=0x4DBF
            | 0x4E00..=0x9FFF
            | 0xA000..=0xA4CF
            | 0xAC00..=0xD7A3
            | 0xF900..=0xFAFF
            | 0xFE10..=0xFE19
            | 0xFE30..=0xFE6F
            | 0xFF00..=0xFF60
            | 0xFFE0..=0xFFE6
            | 0x1F300..=0x1F64F
            | 0x1F900..=0x1F9FF
            | 0x20000..=0x3FFFD
    )
}

pub const fn is_close(kind: TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::BlockEnd
            | TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose)
    )
}

pub const fn is_open(kind: TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::BlockStart
            | TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen)
    )
}

pub const fn closed_by(open: TokenKind) -> TokenKind {
    if matches!(open, TokenKind::BlockStart) {
        return TokenKind::BlockEnd;
    }

    if matches!(open, TokenKind::Punctuation(Punctuation::BracketOpen)) {
        return TokenKind::Punctuation(Punctuation::BracketClose);
    }

    TokenKind::Punctuation(Punctuation::ParenClose)
}

pub const fn opened_by(close: TokenKind) -> TokenKind {
    if matches!(close, TokenKind::BlockEnd) {
        return TokenKind::BlockStart;
    }

    if matches!(close, TokenKind::Punctuation(Punctuation::BracketClose)) {
        return TokenKind::Punctuation(Punctuation::BracketOpen);
    }

    TokenKind::Punctuation(Punctuation::ParenOpen)
}

pub(crate) const fn ends_operand(kind: TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::Identifier
            | TokenKind::Number
            | TokenKind::String
            | TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose)
    )
}

#[derive(Clone, Copy, Debug)]
struct Angle {
    depth: u32,
    drop: u32,
    total: i64,
}

impl Angle {
    const EMPTY: Self = Self {
        depth: 0,
        drop: 0,
        total: 0,
    };

    fn closed(&mut self, width: u32) {
        self.depth = self.depth.saturating_sub(width);
        self.total -= i64::from(width);

        let below = u32::try_from(-self.total).unwrap_or(0);

        self.drop = self.drop.max(below);
    }

    fn joined(self, inner: Self) -> Self {
        let reached = i64::from(self.depth.max(inner.drop)) + inner.total;
        let depth = u32::try_from(reached).expect("a saturating count never falls below zero");
        let below = u32::try_from(-(self.total + inner.total)).unwrap_or(0);

        Self {
            depth,
            drop: self.drop.max(below),
            total: self.total + inner.total,
        }
    }

    fn opened(&mut self) {
        self.depth += 1;
        self.total += 1;
    }
}

#[derive(Debug)]
pub(crate) struct Brackets {
    angles: BoundedVec<u32>,
    blocks: BoundedVec<u32>,
    closes: BoundedVec<u32>,
    held: BoundedVec<u32>,
    nested: BoundedVec<Angle>,
    opens: BoundedVec<u32>,
}

impl Brackets {
    pub(crate) fn reserve(count_max: u32) -> Self {
        Self {
            angles: BoundedVec::reserve(count_max),
            blocks: BoundedVec::reserve(count_max),
            closes: BoundedVec::reserve(count_max),
            held: BoundedVec::reserve(count_max),
            nested: BoundedVec::reserve(count_max),
            opens: BoundedVec::reserve(count_max),
        }
    }

    pub(crate) fn angles_at(&self, position: u32) -> u32 {
        self.angles.get(position as usize).copied().unwrap_or(0)
    }

    pub(crate) fn block_after(&self, position: u32) -> Option<u32> {
        let block = *self.blocks.get(position as usize)?;

        (block != u32::MAX).then_some(block)
    }

    pub(crate) fn close_of(&self, position: u32) -> Option<u32> {
        let close = *self.closes.get(position as usize)?;

        (close != u32::MAX).then_some(close)
    }

    pub(crate) fn open_of(&self, position: u32) -> Option<u32> {
        let open = *self.opens.get(position as usize)?;

        (open != u32::MAX).then_some(open)
    }

    pub(crate) fn build(&mut self, source: &[u8], tokens: &[Token]) -> bool {
        self.closes.clear();
        self.opens.clear();

        for _ in 0..tokens.len() {
            if !self.closes.push(u32::MAX) || !self.opens.push(u32::MAX) {
                return false;
            }
        }

        for kind in [
            TokenKind::BlockStart,
            TokenKind::Punctuation(Punctuation::BracketOpen),
            TokenKind::Punctuation(Punctuation::ParenOpen),
        ] {
            if !self.matched(source, tokens, kind) {
                return false;
            }
        }

        self.blocked(source, tokens) && self.angled(source, tokens)
    }

    fn angled(&mut self, source: &[u8], tokens: &[Token]) -> bool {
        self.angles.clear();
        self.nested.clear();

        let mut held = Angle::EMPTY;

        for token in tokens {
            if !self.angles.push(held.depth) {
                return false;
            }

            if is_open(token.kind) || substituting(source, *token) {
                if !self.nested.push(held) {
                    return false;
                }

                held = Angle::EMPTY;

                continue;
            }

            if is_close(token.kind) {
                held = self
                    .nested
                    .pop()
                    .map_or(Angle::EMPTY, |outer| outer.joined(held));

                continue;
            }

            let text = token.text(source);

            if text == b"<" {
                held.opened();
            } else if !text.is_empty() && text.iter().all(|byte| *byte == b'>') {
                held.closed(count_of(text.len()));
            }
        }

        true
    }

    fn blocked(&mut self, source: &[u8], tokens: &[Token]) -> bool {
        self.blocks.clear();

        for _ in 0..tokens.len() {
            if !self.blocks.push(u32::MAX) {
                return false;
            }
        }

        let mut next = u32::MAX;

        for position in (0..tokens.len()).rev() {
            let token = tokens[position];

            if matches!(token.kind, TokenKind::BlockStart | TokenKind::BlockEnd)
                || substituting(source, token)
            {
                next = count_of(position);
            }

            self.blocks[position] = next;
        }

        true
    }

    fn matched(&mut self, source: &[u8], tokens: &[Token], open: TokenKind) -> bool {
        let close = closed_by(open);

        self.held.clear();

        for position in 0..count_of(tokens.len()) {
            let token = tokens[position as usize];

            let opens =
                token.kind == open || open == TokenKind::BlockStart && substituting(source, token);

            if opens {
                if !self.held.push(position) {
                    return false;
                }

                continue;
            }

            if token.kind != close {
                continue;
            }

            if let Some(held) = self.held.pop() {
                self.closes[held as usize] = position;
                self.opens[position as usize] = held;
            }
        }

        true
    }
}

#[derive(Debug)]
pub(crate) struct Breaks {
    held: BoundedVec<u32>,
    leads: BoundedVec<u32>,
    plain: BoundedVec<u32>,
}

impl Breaks {
    pub(crate) fn reserve(count_max: u32) -> Self {
        Self {
            held: BoundedVec::reserve(count_max),
            leads: BoundedVec::reserve(count_max),
            plain: BoundedVec::reserve(count_max),
        }
    }

    pub(crate) fn counted(&self, from: u32, to: u32) -> u32 {
        assert!(from <= to);

        let start = self.plain.partition_point(|offset| *offset < from);
        let mut stop = start;

        while stop < self.plain.len() && stop - start < NEAR_BREAK_MAX && self.plain[stop] < to {
            stop += 1;
        }

        if stop - start == NEAR_BREAK_MAX {
            stop = self.plain.partition_point(|offset| *offset < to);
        }

        let found = count_of(stop - start);
        let first = self.held.partition_point(|offset| *offset < from);

        let owed = self
            .held
            .get(first)
            .is_some_and(|offset| *offset < to && self.leads[first] < from);

        found + u32::from(owed)
    }

    pub(crate) fn build(&mut self, source: &[u8], carriage: bool) -> bool {
        self.held.clear();
        self.leads.clear();
        self.plain.clear();

        let stop = source.len();
        let mut offset = 0;

        while offset < stop {
            if source[offset] == b'\\' {
                let mut cursor = offset + 1;

                while cursor < stop && matches!(source[cursor], b' ' | b'\t') {
                    cursor += 1;
                }

                let width = line_break_width(source, cursor);

                if width > 0 {
                    let counts = carriage || source[cursor] == b'\n' || width == 2;

                    if counts
                        && (!self.held.push(count_of(cursor)) || !self.leads.push(count_of(offset)))
                    {
                        return false;
                    }

                    offset = cursor + width;

                    continue;
                }
            }

            let width = line_break_width(source, offset);

            if width > 0 && (carriage || source[offset] == b'\n' || width == 2) {
                if !self.plain.push(count_of(offset)) {
                    return false;
                }

                offset += width;

                continue;
            }

            offset += 1;
        }

        true
    }
}

pub fn span_of(bytes: &[u8], lines: (u32, u32)) -> Option<Span> {
    assert!(lines.0 <= lines.1);

    let mut line = 0;
    let mut offset = 0;
    let mut start = None;
    let mut end = count_of(bytes.len());

    for position in 0..count_of(bytes.len()) {
        if line == lines.0 && start.is_none() {
            start = Some(offset);
        }

        if line == lines.1 + 1 {
            end = offset;

            break;
        }

        if bytes[position as usize] == b'\n' {
            line += 1;
            offset = position + 1;
        }
    }

    if line == lines.0 && start.is_none() {
        start = Some(offset);
    }

    let first = start?;

    assert!(end >= first);

    Some(Span {
        length: end - first,
        offset: first,
    })
}
