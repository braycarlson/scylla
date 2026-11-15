pass
del a
del a, b
global g
nonlocal_placeholder = 1
assert a
assert a, "message"
raise
raise ValueError
raise ValueError("text")
raise ValueError from cause
a = 1
b = 2
c = 3


def scoped():
    inner = 1

    def nested():
        nonlocal inner
        inner = 2

    return nested
