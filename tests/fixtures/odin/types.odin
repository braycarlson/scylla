package fixtures

import "core:fmt"

// The construct fixtures for the type grammar.

/*
A block comment, which the lexer keeps whole.
*/

Slice :: []u8
Pointer :: ^int
Array :: [4]int
Dynamic :: [dynamic]int
Many :: [^]int
Table :: map[string]int
Set :: bit_set[Colour]
Matrix :: matrix[2, 2]f32
Procedure :: proc(a: int, b: int) -> int
Nested :: ^[]^int

Colour :: enum {
	Red,
	Green,
}

Holder :: struct {
	values: [dynamic]int,
	lookup: map[string]int,
	target: ^int,
	action: proc(a: int),
}

typed :: proc(value: ^Holder) -> ^int {
	return value.target
}

Inline :: struct {
	nested: struct {
		left: int,
	},
	chosen: enum {
		One,
		Two,
	},
	either: union {
		int,
		string,
	},
}

Flags :: bit_field u8 {
	low: u8 | 4,
	high: u8 | 4,
}

Pair :: struct($T: typeid) {
	value: T,
}

Boxed :: Pair(int)

Limit: int: 3

made :: proc() -> matrix[2, 2]f32 {
	return matrix[2, 2]f32{1, 2, 3, 4}
}

masked :: proc() -> bit_set[Colour] {
	return bit_set[Colour]{.Red}
}

printed :: proc(value: fmt.Info) {
}

Bits :: struct {
	held: bit_field u8 {
		one: bool | 1,
		two: u8 | 7,
	},
}

Chosen :: proc() {
	value: (int when true else f32) = 1

	_ = value
}
