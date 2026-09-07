pub const CLAUSE_COUNT_MAX: usize = 16;
pub const PART_COUNT: usize = 3;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Operator {
    Caret,
    Compatible,
    Equal,
    Greater,
    GreaterEqual,
    Less,
    LessEqual,
    NotEqual,
}

pub fn satisfies(held: &[u8], requirement: &[u8]) -> bool {
    let mut start = 0_usize;

    for _ in 0..CLAUSE_COUNT_MAX {
        if start >= requirement.len() {
            return true;
        }

        let rest = requirement.get(start..).unwrap_or_default();
        let end = rest
            .iter()
            .position(|byte| *byte == b',')
            .map_or(requirement.len(), |offset| start.saturating_add(offset));

        if !clause_satisfied(held, requirement.get(start..end).unwrap_or_default()) {
            return false;
        }

        start = end.saturating_add(1);
    }

    start >= requirement.len()
}

fn clause_satisfied(held: &[u8], clause: &[u8]) -> bool {
    let trimmed = clause.trim_ascii();

    if trimmed.is_empty() {
        return true;
    }

    let (operator, rest) = operator_of(trimmed);
    let wanted = rest.trim_ascii();
    let left = numbered(held);
    let right = numbered(wanted);
    let spelled = part_count_of(wanted);

    match operator {
        Operator::Caret => left >= right && left[0] == right[0],
        Operator::Compatible => left >= right && same_series(&left, &right, spelled),
        Operator::Equal => prefix_equal(&left, &right, spelled),
        Operator::Greater => left > right,
        Operator::GreaterEqual => left >= right,
        Operator::Less => left < right,
        Operator::LessEqual => left <= right,
        Operator::NotEqual => !prefix_equal(&left, &right, spelled),
    }
}

fn numbered(version: &[u8]) -> [u64; PART_COUNT] {
    let mut parts = [0_u64; PART_COUNT];
    let mut index = 0_usize;

    for field in version.split(|byte| *byte == b'.') {
        let Some(slot) = parts.get_mut(index) else {
            break;
        };

        let mut value = 0_u64;

        for digit in field.iter().take_while(|byte| byte.is_ascii_digit()) {
            value = value
                .saturating_mul(10)
                .saturating_add(u64::from(digit.saturating_sub(b'0')));
        }

        *slot = value;
        index = index.saturating_add(1);
    }

    assert!(index <= PART_COUNT);

    parts
}

fn operator_of(clause: &[u8]) -> (Operator, &[u8]) {
    let two: [(&[u8], Operator); 5] = [
        (b"~=", Operator::Compatible),
        (b"==", Operator::Equal),
        (b">=", Operator::GreaterEqual),
        (b"<=", Operator::LessEqual),
        (b"!=", Operator::NotEqual),
    ];

    for (spelling, operator) in two {
        if let Some(rest) = clause.strip_prefix(spelling) {
            return (operator, rest);
        }
    }

    let one: [(u8, Operator); 4] = [
        (b'>', Operator::Greater),
        (b'<', Operator::Less),
        (b'^', Operator::Caret),
        (b'=', Operator::Equal),
    ];

    for (spelling, operator) in one {
        if let Some(rest) = clause.strip_prefix(&[spelling]) {
            return (operator, rest);
        }
    }

    (Operator::Equal, clause)
}

fn part_count_of(version: &[u8]) -> usize {
    let dots = version.split(|byte| *byte == b'.').count();

    dots.min(PART_COUNT)
}

fn prefix_equal(left: &[u64; PART_COUNT], right: &[u64; PART_COUNT], spelled: usize) -> bool {
    assert!(spelled <= PART_COUNT);

    left[..spelled] == right[..spelled]
}

fn same_series(left: &[u64; PART_COUNT], right: &[u64; PART_COUNT], spelled: usize) -> bool {
    assert!(spelled <= PART_COUNT);

    if spelled <= 1 {
        return true;
    }

    let held = spelled.saturating_sub(1);

    left[..held] == right[..held]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_requirement_is_satisfied_by_every_version() {
        assert!(satisfies(b"1.2.3", b""));
        assert!(satisfies(b"1.2.3", b"   "));
        assert!(satisfies(b"1.2.3", b" , "));
    }

    #[test]
    fn each_operator_compares_the_way_its_spelling_says() {
        assert!(satisfies(b"1.2.3", b">=1.2.3"));
        assert!(satisfies(b"1.2.3", b">= 1.2"));
        assert!(!satisfies(b"1.2.3", b">=1.3"));
        assert!(satisfies(b"1.2.3", b">1.2.2"));
        assert!(!satisfies(b"1.2.3", b">1.2.3"));
        assert!(satisfies(b"1.2.3", b"<=1.2.3"));
        assert!(!satisfies(b"1.2.3", b"<=1.2.2"));
        assert!(satisfies(b"1.2.3", b"<2"));
        assert!(!satisfies(b"1.2.3", b"<1.2.3"));
        assert!(satisfies(b"1.2.3", b"!=1.2.4"));
        assert!(!satisfies(b"1.2.3", b"!=1.2"));
    }

    #[test]
    fn an_equality_holds_over_the_parts_the_requirement_spells() {
        assert!(satisfies(b"1.2.3", b"==1.2.3"));
        assert!(satisfies(b"1.2.3", b"==1.2"));
        assert!(satisfies(b"1.2.3", b"=1"));
        assert!(satisfies(b"1.2.3", b"1.2.3"));
        assert!(!satisfies(b"1.2.3", b"==1.2.4"));
        assert!(!satisfies(b"1.2.3", b"1.3"));
    }

    #[test]
    fn a_compatible_release_stays_in_its_series() {
        assert!(satisfies(b"1.2.3", b"~=1.2"));
        assert!(satisfies(b"1.9.0", b"~=1.2"));
        assert!(!satisfies(b"2.0.0", b"~=1.2"));
        assert!(satisfies(b"1.2.9", b"~=1.2.3"));
        assert!(!satisfies(b"1.3.0", b"~=1.2.3"));
        assert!(!satisfies(b"1.2.2", b"~=1.2.3"));
        assert!(satisfies(b"7.0.0", b"~=1"));
    }

    #[test]
    fn a_caret_stays_in_its_major() {
        assert!(satisfies(b"1.2.3", b"^1.2"));
        assert!(satisfies(b"1.9.9", b"^1.2.3"));
        assert!(!satisfies(b"2.0.0", b"^1.2.3"));
        assert!(!satisfies(b"1.2.2", b"^1.2.3"));
    }

    #[test]
    fn comma_clauses_all_have_to_hold() {
        assert!(satisfies(b"1.2.3", b">=1.0, <2.0"));
        assert!(!satisfies(b"2.1.0", b">=1.0, <2.0"));
        assert!(!satisfies(b"0.9.0", b">=1.0,<2.0"));
        assert!(satisfies(b"1.2.3", b">=1.0,,<2.0,"));
    }

    #[test]
    fn a_version_with_a_suffix_reads_its_digits_only() {
        assert_eq!(numbered(b"1.2.3-beta"), [1, 2, 3]);
        assert_eq!(numbered(b"1.2"), [1, 2, 0]);
        assert_eq!(numbered(b"1.2.3.4"), [1, 2, 3]);
        assert_eq!(numbered(b""), [0, 0, 0]);
        assert_eq!(part_count_of(b"1.2.3.4"), 3);
        assert_eq!(part_count_of(b"1"), 1);
    }
}
