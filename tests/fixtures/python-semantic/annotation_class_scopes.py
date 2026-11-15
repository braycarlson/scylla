from typing import Annotated


def outer():
    def inner():
        class Model:
            ann: Annotated[List[Dict[str, str]], 1]

        Dict = dict

        return Model

    List = list

    Model = inner()

    return Model


def outer_d2():
    def inner():
        class Model:
            ann: List

        return Model

    List = list

    return inner()


def outer_d3():
    def inner():
        class Model:
            ann: Dict

        Dict = dict

        return Model

    return inner()


def outer_d4():
    class Model:
        ann: List

    List = list

    return Model


def outer_d5():
    def inner(x: List) -> Later:
        return x

    List = list
    Later = int

    return inner


def outer_d6():
    def mid():
        def inner(x: List) -> Later:
            return x

        return inner

    List = list
    Later = int

    return mid


def outer_d7():
    class A:
        class B:
            ann: List

    List = list

    return A


def other_d7():
    def inner():
        class A:
            class B:
                ann: Later

        return A

    Later = int

    return inner


def f_d8(x: Later): ...


Later_d8 = int


class C_d8:
    x: Missing

    def m(self):
        class D:
            y: Field

        return D

    Field = int


Missing_d8 = int
