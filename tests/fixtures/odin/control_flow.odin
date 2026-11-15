#+build !js
package fixtures

run :: proc(values: []int, flag: bool) -> int {
	total := 0

	if flag {
		total += 1
	} else if len(values) > 0 {
		total += 2
	} else {
		total = 3
	}

	for value, index in values {
		total += value * index
	}

	for i := 0; i < 10; i += 1 {
		total -= 1
	}

	for {
		break
	}

	outer: for i in 0 ..< 4 {
		if i == 0 {
			continue outer
		}

		break outer
	}

	switch total {
	case 0:
		total = 4
	case 1, 2:
		total = 5
	case:
		total = 6
	}

	defer total = 0

	when ODIN_DEBUG {
		total = 7
	}

	return total
}

fallen :: proc(value: int) {
	switch value {
	case 1:
		fallthrough
	case 2 ..= 3:
		break
	case 4 ..< 6:
		break
	}
}

shortened :: proc(flag: bool) {
	if flag do return
}

when ODIN_OS == .Linux {
	Platform :: int
} else when ODIN_OS == .Windows {
	Platform :: uint
} else {
	Platform :: i64
}

guarded :: proc() {
	#no_bounds_check
	#bounds_check {
		value := 1

		_ = value
	}
}
