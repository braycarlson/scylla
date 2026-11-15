package fixture

type Types struct {
	slice     []int
	array     [4]int
	pointer   *int
	mapping   map[string]int
	channel   chan int
	receive   <-chan int
	send      chan<- int
	function  func(int) (string, error)
	anonymous struct{ Held int }
	interfaced interface{ Name() string }
	empty     interface{}
	nested    map[string][]*Types
	variadic  func(...int)
}

type Constraint interface {
	~int | ~int64
}

type Generic[T Constraint] struct {
	held T
}

func (g Generic[T]) value() T {
	return g.held
}

type Instantiated = Generic[int]
