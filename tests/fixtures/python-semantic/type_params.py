type Alias[T] = list[T]


def run[T](value: T) -> T:
    return value


class Holder[T]:
    def read(self) -> T:
        return self
