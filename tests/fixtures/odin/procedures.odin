package fixtures

add :: proc(a: int, b: int) -> int {
	return a + b
}

divide :: proc(a: int, b: int) -> (result: int, ok: bool) {
	if b == 0 {
		return 0, false
	}

	return a / b, true
}

defaulted :: proc(a: int, b: int = 2) -> int {
	return a + b
}

generic :: proc($T: typeid, value: T) -> T {
	return value
}

variadic :: proc(values: ..int) -> int {
	total := 0

	for value in values {
		total += value
	}

	return total
}

anonymous :: proc() {
	handler := proc(a: int) -> int {
		return a
	}

	_ = handler
}

defaulted_inferred :: proc(scale := 2) -> int {
	return scale
}

counted :: proc(values: ..int) -> int {
	total := 0

	for value in values {
		total += value
	}

	return total
}

bounded :: proc($T: typeid, value: T) -> T where size_of(T) > 0 {
	return value
}

specialised :: proc(value: $T/int) -> T {
	return value
}

conventional :: proc "c" (value: int) -> int {
	return value
}

spread :: proc(values: []int) -> int {
	return counted(..values)
}

boxed :: proc(value: Pair(int)) -> int {
	return value.value
}

defaulted_result :: proc() -> (ok := true) {
	return
}

diverging :: proc() -> ! {
	for {
	}
}

called :: proc(reader: ^Reader) {
	reader->read()
}
