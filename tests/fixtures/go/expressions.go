package fixture

func run() {
	sum := 1 + 2*3 - 4/5%6
	bits := 1 & 2 | 3 ^ 4 &^ 5
	shifted := 1<<2 | 8>>3
	compared := 1 == 2 && 3 != 4 || 5 < 6 && 7 > 8 || 9 <= 10 || 11 >= 12
	unary := -sum
	inverted := ^sum
	negated := !compared
	pointer := &sum
	value := *pointer
	grouped := (1 + 2) * 3
	call := helper(1, 2)
	chained := outer(inner(1))
	selected := pack.Field
	method := pack.Method(1)
	indexed := names[0]
	sliced := names[1:2]
	capped := names[1:2:3]
	open := names[:]
	composite := Pair{Left: 1, Right: "two"}
	positional := Pair{1, "two"}
	nested := [][]int{{1}, {2}}
	mapping := map[string]int{"a": 1}
	asserted := any.(Pair)
	converted := int64(sum)
	variadic := helper(rest...)

	sum += 1
	sum -= 1
	sum *= 2
	sum /= 2
	sum %= 2
	sum &= 1
	sum |= 1
	sum ^= 1
	sum &^= 1
	sum <<= 1
	sum >>= 1
	sum = 1
	sum++
	sum--

	channel := make(chan int, 1)
	channel <- sum
	<-channel

	_ = bits
	_ = shifted
	_ = unary
	_ = inverted
	_ = negated
	_ = value
	_ = grouped
	_ = call
	_ = chained
	_ = selected
	_ = method
	_ = indexed
	_ = sliced
	_ = capped
	_ = open
	_ = composite
	_ = positional
	_ = nested
	_ = mapping
	_ = asserted
	_ = converted
	_ = variadic
}
