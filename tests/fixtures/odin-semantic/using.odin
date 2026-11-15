package sample

Holder :: struct {
	field: int,
}

read :: proc(self: Holder) -> int {
	using self

	return field
}

plain :: proc(self: Holder) -> int {
	return missing
}
