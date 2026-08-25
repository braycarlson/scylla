#[derive(Clone, Copy, Debug, Default, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum Dialect {
    #[default]
    Ts,
    Tsx,
}

impl Dialect {
    pub const fn is_tsx(self) -> bool {
        matches!(self, Self::Tsx)
    }

    pub const fn name(self) -> &'static str {
        match self {
            Self::Ts => "ts",
            Self::Tsx => "tsx",
        }
    }

    pub fn of_extension(extension: &str) -> Option<Self> {
        match extension {
            "cts" | "mts" | "ts" => Some(Self::Ts),
            "tsx" => Some(Self::Tsx),
            _ => None,
        }
    }
}
