package sample

type node struct {
	id int
}

type sorter func(left int, right int) bool

type Pair[Key ordered, Value any] struct {
	key   Key
	value Value
}

type Other[Key ordered, Value any] struct {
	key   Key
	value Value
}

type ordered interface {
	~int | ~string
}

var left = 5

var two = 7

var compare sorter

// A parameter and a result belong to the body, so both types here name the type above.
func find(node *node) *node {
	return node
}

func (p *Pair[Key, Value]) First() Key {
	return p.key
}

func second[Map ~map[Key]Value, Key ordered, Value any](held Map) Value {
	var found Value

	for _, value := range held {
		found = value
	}

	return found
}

// A `:=` opens at the end of the statement it is written in, so the right side reads
// whatever stood before it.
func shadow() int {
	value := left

	{
		value := value + 1

		return value
	}
}

// The `:=` inside the literal is the literal's own, so this assigns rather than declares.
func assign() {
	compare = func(one int, two int) bool {
		held := one < two

		return held
	}
}

// The parameters of a function type a signature names are that type's own.
func apply(handler func(one int, two int) bool) bool {
	return handler(1, two)
}

func loops(items []int) int {
	total := left

	for index, item := range items {
		total = total + index + item
	}

	var line int

	for line = range items {
		step := line

		total = total + step
	}

	return total
}
