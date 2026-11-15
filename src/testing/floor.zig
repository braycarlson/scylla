const std = @import("std");
const assert = std.debug.assert;

pub const Relation = struct {
    corpus: u32,
    every: u32,
    window: u32,
};

const Relations = struct {
    built: u32,
    renamed: u32,
};

const Resolve = struct {
    files: u32,
    rows: u32,
};

const corpus_pin: u64 = 0xd64a_a8ef_546b_e45d;
pub const corpus_classify_css: u32 = 1_661;
pub const corpus_classify_go: u32 = 7_726;
pub const corpus_classify_javascript: u32 = 15_865;
pub const corpus_classify_odin: u32 = 2_007;
pub const corpus_classify_python: u32 = 9_378;
pub const corpus_classify_rust: u32 = 10_357;
pub const corpus_classify_typescript: u32 = 28_973;
pub const corpus_classify_zig: u32 = 4_363;
pub const corpus_census_python: u32 = 9_373;
pub const corpus_walk_css: u32 = 1_497;
pub const corpus_walk_go: u32 = 7_682;
pub const corpus_walk_javascript: u32 = 15_030;
pub const corpus_walk_odin: u32 = 1_946;
pub const corpus_walk_python: u32 = 9_376;
pub const corpus_walk_rust: u32 = 9_911;
pub const corpus_walk_typescript: u32 = 28_815;
pub const corpus_walk_zig: u32 = 4_363;
pub const corpus_scope_python: u32 = 9_376;
pub const corpus_resolve_javascript: u32 = 43_205;
pub const corpus_semantic_go: u32 = 7_678;
pub const corpus_semantic_javascript: u32 = 43_232;
pub const corpus_semantic_python: u32 = 9_376;
pub const corpus_lossless: u32 = 82_322;
pub const fixture_format_css: u32 = 3;
pub const fixture_format_go: u32 = 6;
pub const fixture_format_javascript: u32 = 15;
pub const fixture_format_odin: u32 = 5;
pub const fixture_format_python: u32 = 20;
pub const fixture_format_rust: u32 = 8;
pub const fixture_format_typescript: u32 = 23;
pub const fixture_format_zig: u32 = 5;
pub const fixture_walk_css: u32 = 5;
pub const fixture_walk_go: u32 = 6;
pub const fixture_walk_javascript: u32 = 18;
pub const fixture_walk_odin: u32 = 5;
pub const fixture_walk_python: u32 = 20;
pub const fixture_walk_rust: u32 = 8;
pub const fixture_walk_typescript: u32 = 26;
pub const fixture_walk_zig: u32 = 5;
pub const fixture_scope_python: u32 = 20;
pub const fixture_resolve_javascript: u32 = 27;
pub const fixture_semantic_go: u32 = 5;
pub const fixture_semantic_javascript: u32 = 24;
pub const fixture_lossless: u32 = 93;
pub const relation_css: Relation = .{ .corpus = 1_621, .every = 5, .window = 5 };
pub const relation_go: Relation = .{ .corpus = 7_678, .every = 6, .window = 6 };
pub const relation_javascript: Relation = .{ .corpus = 14_078, .every = 18, .window = 17 };
pub const relation_odin: Relation = .{ .corpus = 1_995, .every = 5, .window = 5 };
pub const relation_python: Relation = .{ .corpus = 9_375, .every = 20, .window = 20 };
pub const relation_rust: Relation = .{ .corpus = 10_117, .every = 8, .window = 8 };
pub const relation_tsx: Relation = .{ .corpus = 552, .every = 6, .window = 5 };
pub const relation_typescript: Relation = .{ .corpus = 27_955, .every = 20, .window = 20 };
pub const relation_zig: Relation = .{ .corpus = 4_317, .every = 5, .window = 5 };
const corpus_relations_go: Relations = .{ .built = 7_677, .renamed = 7_030 };
const corpus_relations_javascript: Relations = .{ .built = 14_078, .renamed = 8_878 };
const corpus_relations_odin: Relations = .{ .built = 1_995, .renamed = 1_761 };
const corpus_relations_python: Relations = .{ .built = 9_375, .renamed = 7_738 };
const corpus_relations_rust: Relations = .{ .built = 10_117, .renamed = 8_838 };
const corpus_relations_typescript: Relations = .{ .built = 27_955, .renamed = 25_619 };
const corpus_relations_zig: Relations = .{ .built = 4_317, .renamed = 4_115 };
pub const corpus_census_css: u32 = 1_487;
pub const corpus_census_go: u32 = 7_680;
pub const corpus_census_javascript: u32 = 14_445;
pub const corpus_census_odin: u32 = 1_929;
pub const corpus_census_rust: u32 = 9_893;
pub const corpus_census_typescript: u32 = 28_762;
pub const corpus_census_zig: u32 = 4_363;
pub const corpus_format_markup: u32 = 4_004;
pub const corpus_markup_lex: u32 = 4_080;
pub const corpus_markup_tree: u32 = 4_080;
pub const corpus_semantic_css: u32 = 1_668;
pub const corpus_postcss_css: u32 = 1_646;
pub const corpus_parse5_markup: Resolve = .{ .files = 4_080, .rows = 457_448 };
pub const corpus_resolve_zig: Resolve = .{ .files = 4_363, .rows = 1_275_956 };
pub const corpus_resolve_rust: Resolve = .{ .files = 7_104, .rows = 728_058 };
pub const corpus_resolve_odin: Resolve = .{ .files = 1_993, .rows = 329_350 };
const fnv_offset_basis: u64 = 0xcbf2_9ce4_8422_2325;
const fnv_prime: u64 = 0x0000_0100_0000_01b3;
const manifest_bytes_max = 1 << 16;
const manifest_path = "corpus/manifest.txt";

const corpus_relations = std.StaticStringMap(Relations).initComptime(.{
    .{ "go", corpus_relations_go },
    .{ "javascript", corpus_relations_javascript },
    .{ "odin", corpus_relations_odin },
    .{ "python", corpus_relations_python },
    .{ "rust", corpus_relations_rust },
    .{ "typescript", corpus_relations_typescript },
    .{ "zig", corpus_relations_zig },
});

fn pin_of(manifest: []const u8) u64 {
    var held: u64 = fnv_offset_basis;

    assert(manifest.len <= manifest_bytes_max);

    for (manifest) |byte| {
        held ^= byte;
        held *%= fnv_prime;
    }

    if (manifest.len == 0) assert(held == fnv_offset_basis);

    return held;
}

pub fn corpus_relations_of(name: []const u8) Relations {
    assert(name.len > 0);

    const held = corpus_relations.get(name);

    assert(held != null);

    return held.?;
}

test "the floors name the corpus they were counted over" {
    var buffer: [manifest_bytes_max]u8 = undefined;
    const manifest = try std.Io.Dir.cwd().readFile(std.testing.io, manifest_path, &buffer);
    const held = pin_of(manifest);

    try std.testing.expect(manifest.len < buffer.len);

    if (held != corpus_pin) {
        std.debug.print(
            "{s} hashes to 0x{x:0>16} and the floors were counted over 0x{x:0>16}: " ++
                "re-count the floors against the corpus this manifest resolves to " ++
                "and stamp the new pin\n",
            .{ manifest_path, held, corpus_pin },
        );
    }

    try std.testing.expectEqual(corpus_pin, held);
}

test "every relations floor renames no more than it builds" {
    for (corpus_relations.keys()) |name| {
        const relations = corpus_relations_of(name);

        try std.testing.expect(relations.renamed <= relations.built);
    }

    try std.testing.expectEqual(corpus_relations_zig, corpus_relations_of("zig"));
}
