def outer():
    def inner():
        nonlocal missing
        missing = 1

    return inner
