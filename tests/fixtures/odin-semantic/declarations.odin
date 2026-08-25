package sample

import "core:fmt"
import str "core:strings"

TOP :: 4

Shade :: enum {
	Light,
	Dark,
}

Holder :: struct {
	field: int,
	shade: Shade,
}

Handler :: proc(one: int) -> int

top :: proc() -> int {
	fmt.println(str.to_upper("x"))

	return TOP
}
