from string.templatelib import Template
from templates import render


def basic() -> Template:
    first = 5
    second = 10
    return t"select {first}, {second}"


def nested():
    value = 1
    spec = ">10"
    return t"{value:{spec}} {render(value)!r}"


def concatenated():
    name = "x"
    return t"a {name}" t"b"
