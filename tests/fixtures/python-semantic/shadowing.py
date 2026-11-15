value = 1


def outer():
    value = 2

    def inner():
        return value

    return inner


def reader():
    return value
