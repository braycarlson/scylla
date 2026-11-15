package fixtures

import "core:fmt"
import str "core:strings"

Point :: struct {
	x: int,
	y: int,
}

Tagged :: struct #packed {
	flag: bool,
}

Colour :: enum u8 {
	Red,
	Green = 4,
	Blue,
}

Value :: union {
	int,
	string,
}

MAX :: 10
NAME :: "held"

counter: int
first, second: f32

Alias :: distinct int

Callback :: proc(a: int) -> int
