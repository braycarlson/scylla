package sample

import (
	"fmt"
	alias "strings"
	_ "embed"
	"net/http"
	. "math"
)

func use() {
	fmt.Println(alias.ToUpper("a"))
	http.Get("b")
	fmt.Println(Pi)
}

func dotted() float64 {
	Pi := 3.0

	return Sqrt(Pi)
}
