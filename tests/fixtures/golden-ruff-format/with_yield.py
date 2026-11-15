def generator():
    yield
    yield 1
    yield from other()
    x = yield 2


async def asynchronous():
    async with resource() as handle:
        pass

    async for item in stream():
        pass


def contexts():
    with open("a") as handle:
        pass

    with open("a") as first, open("b") as second:
        pass

    with open("a") as first, open("b") as second:
        pass

    with open("a"):
        pass
