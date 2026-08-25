package fixture

func plain() {}

func arguments(one int, two, three string, rest ...bool) {}

func unnamed(int, string) bool {
	return true
}

func results() (int, error) {
	return 0, nil
}

func named() (value int, err error) {
	return
}

func single() string {
	return ""
}

type Holder struct {
	held int
}

func (h Holder) value() int {
	return h.held
}

func (h *Holder) pointer() {
	h.held = 1
}

func generic[T any, U comparable](one T, two U) T {
	return one
}

func literals() {
	held := func(one int) int { return one }
	_ = held(1)

	go func() {}()
	defer func() {}()
}
