def outer():
    held = 1

    def inner():
        nonlocal held
        held = 2

    inner()

    return held


def bare():
    def inner():
        nonlocal missing
        missing = 1

    return inner
