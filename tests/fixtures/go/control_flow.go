package fixture

func run(value int) int {
	if value > 0 {
		value++
	} else if value < 0 {
		value--
	} else {
		value = 0
	}

	if held := value * 2; held > 4 {
		value = held
	}

	for i := 0; i < 3; i++ {
		value += i
	}

	for value > 0 {
		value--
	}

	for {
		break
	}

	for index, held := range names {
		value += index + len(held)
	}

	for range names {
		value++
	}

	switch value {
	case 0:
		value = 1
	case 1, 2:
		value = 3
	default:
		value = 4
	}

	switch held := value; held {
	case 0:
		fallthrough
	default:
	}

	switch any := interface{}(value).(type) {
	case int:
		_ = any
	case string, bool:
	default:
	}

	select {
	case held := <-channel:
		_ = held
	case channel <- value:
	default:
	}

	outer:
	for {
		for {
			continue outer
		}
	}

	goto done

done:
	return value
}
