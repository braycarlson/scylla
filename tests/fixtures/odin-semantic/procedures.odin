package sample

build :: proc(one: int, two: string) -> (held: int, ok: bool) {
	held = one
	kept := two
	total: int = one

	for item, index in kept {
		total += index
	}

	if total > 0 {
		inner := total

		total = inner
	}

	switch total {
	case 0:
		total = 1
	case:
		total = 2
	}

	outer: for {
		break outer
	}

	defer teardown(total)

	return total, true
}

teardown :: proc(one: int) {
}

read :: proc(one: int) -> int {
	return one
}

group :: proc{build, read}
