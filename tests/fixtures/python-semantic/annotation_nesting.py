from typing import Annotated
from typing import Annotated, Callable
from typing import Annotated, List


def f():
    types = {}
    items: list["types['Expression']"] = []
    other: List["'Deep'"] = []
    return items, other


def g():
    @staticmethod
    def h():
        pass

    class A:
        a: """Annotated[
            Forward,
            int
        ]""" = True
        b: """
            Second
        """ = 1

    Forward = bool
    Second = int

    return A


def f():
    a: "Annotated[int, (lambda name, _: name)]" = 1
    b: "Annotated[int, [v for v in Missing1 if v]]" = 1
    c: "Callable[[int], (lambda q=Missing2: q)]" = 1
    d: "list[[x for x in x]]" = 1
    e: "list[[(y, z) for y, z in Missing3]]" = 1
    g: "list[(w := Missing4)]" = 1
    return a, b, c, d, e, g


def f():
    g: "list[(w := int)]" = []
    h: "list[(lambda: (v := 1))]" = []
    return g, h


def k():
    z: "list[(u := int)]" = []
    print(u)
    return z
def m():
    q: "list[(lambda: ((t := 1), t))]" = []
    return q
