package fixtures

Point :: struct {
	x: int,
	y: int,
}

run :: proc(values: []int) {
	sum := 1 + 2 * 3 - 4 / 5 % 6
	bits := (1 << 2) | (3 >> 1) & 4 ~ 5
	logic := true && false || !true
	compare := 1 == 2 || 3 != 4 || 5 < 6 || 7 > 8 || 9 <= 10 || 11 >= 12
	member := values[0]
	sliced := values[1:2]
	opened := values[1:]
	point := Point{x = 1, y = 2}
	array := [4]int{1, 2, 3, 4}
	table := map[string]int{"one" = 1}
	pointer := &sum
	pointed := pointer^
	casted := cast(f32)sum
	moved := transmute(u32)sum
	grouped := (sum + 1) * 2
	member_call := fmt.println(sum)
	chained := point.x
	literal := 'c'
	text := "held"
	raw := `held`
	real := 1.5
	nothing := nil
	blank := ---

	_ = bits
	_ = logic
	_ = compare
	_ = member
	_ = sliced
	_ = opened
	_ = array
	_ = table
	_ = pointed
	_ = casted
	_ = moved
	_ = grouped
	_ = member_call
	_ = chained
	_ = literal
	_ = text
	_ = raw
	_ = real
	_ = nothing
	_ = blank
}

assigned :: proc(held: ^int) {
	held^ += 1
	held^ -= 1
	held^ *= 2
	held^ /= 2
	held^ %= 2
	held^ &= 1
	held^ |= 1
	held^ ~= 1
	held^ &~= 1
	held^ <<= 1
	held^ >>= 1
	held^ &&= true
	held^ ||= true
}

remainder :: proc(left: int, right: int) -> int {
	return left %% right
}

cleared :: proc(left: int, right: int) -> int {
	return left &~ right
}

chosen :: proc(flag: bool) -> int {
	return flag ? 1 : 2
}

converted :: proc(value: int) -> f32 {
	return auto_cast value
}

recovered :: proc(lookup: map[string]int) -> int {
	value := lookup["held"] or_else 0

	return value
}

returned :: proc(lookup: map[string]int) -> (int, bool) {
	value := recovered(lookup) or_return

	return value, true
}

looped :: proc(values: []int, lookup: map[string]int) {
	for value in values {
		if value not_in lookup {
			continue
		}

		held := value or_break
		other := value or_continue

		_ = held
		_ = other
	}
}

scoped :: proc() {
	held := context
	context.user_index = 1

	_ = held
}
