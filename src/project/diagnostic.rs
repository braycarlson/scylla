#[expect(
    clippy::struct_field_names,
    reason = "each field is a bound, and `_max` is what every bound in this tree is named"
)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Budget {
    pub arena_bytes_max: u32,
    pub diagnostic_bytes_max: u32,
    pub diagnostic_count_max: u32,
    pub edge_count_max: u32,
    pub edit_count_max: u32,
    pub fix_count_max: u32,
}
