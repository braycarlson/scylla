package fixture

import (
	_ "embed"
	"fmt"
	. "math"
	str "strings"
)

import "os"

const Limit = 8

const (
	One = iota
	Two
	Three int = 3
)

var names = []string{"one", "two"}

var (
	first  int
	second      = 2
	third  bool = true
)

type Pair struct {
	Left  int
	Right string
	tag   string `json:"tag"`
	embedded
	*Pointer
}

type Named interface {
	Name() string
	fmt.Stringer
	~int | ~string
}

type Alias = Pair

type Number int

type Callback func(one int, two string) (int, error)

type Mapping map[string][]int

type Channel chan<- int

type embedded struct{}

type Pointer struct{}

func use() {
	_ = fmt.Sprint(names, str.ToUpper("x"), Pi, os.Args, Limit, One, Two, Three)
	_ = first
	_ = second
	_ = third
}
