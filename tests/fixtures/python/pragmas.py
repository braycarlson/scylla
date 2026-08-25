def held(a):
    # fmt: off
    if a:
          b = [1,2,
     3]
    # fmt: on
    c = [1, 2, 3]

    return b, c


def skipped(a):
    d = [1,  2]  # fmt: skip

    return d


def unclosed(a):
    # fmt: off
    if a:
          e = [1,2,
     3]


f = [1, 2, 3]
