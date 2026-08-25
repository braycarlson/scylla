package sample

func kinds(value any) int {
	switch held := value.(type) {
	case int:
		return held
	case string:
		return len(held)
	}

	return 0
}

func short() int {
	one, two := 1, 2
	one, three := 3, 4

	return one + two + three
}
