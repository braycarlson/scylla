package sample

import "strings"

var top = 1

func outer() int {
	held := top

	{
		inner := held

		return inner
	}
}

func later() int {
	return outer() + len(strings.Fields("a"))
}
