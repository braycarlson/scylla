package sample

import "core:c"

foreign import lib "system:lib"

@(default_calling_convention = "c")
foreign lib {
	native :: proc(one: int) -> int ---
}

call :: proc() -> int {
	return native(1)
}
