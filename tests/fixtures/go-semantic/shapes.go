package sample

type Widget struct {
	Name string
}

func (widget *Widget) Rename(held string) string {
	widget.Name = held

	return widget.Name
}

func pairs(one, two int) (first int, second int) {
	first = one
	second = two

	return first, second
}

func labelled() {
	outer:
	for index := 0; index < 3; index++ {
		if index == 1 {
			break outer
		}
	}
}
