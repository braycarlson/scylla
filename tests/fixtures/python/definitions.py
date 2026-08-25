def plain():
    pass


def positional(a, b):
    pass


def defaulted(a, b=1):
    pass


def annotated(a: int, b: str = "x") -> bool:
    return True


def starred(a, *rest, key=1, **extra):
    pass


def positional_only(a, b, /, c, *, d):
    pass


async def asynchronous():
    await other()


def nested():
    def inner():
        pass

    return inner
