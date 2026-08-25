type Alias = int
type Generic[T] = list[T]
type Pair[T, U] = dict[T, U]


def function[T](value: T) -> T:
    return value


def variadic[*Ts](*values: *Ts) -> None:
    pass


def spec[**P](callback) -> None:
    pass


class Container[T]:
    def get(self) -> T:
        raise NotImplementedError
