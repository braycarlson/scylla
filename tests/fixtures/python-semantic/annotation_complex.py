from typing import Dict, List, Optional, TypeVar, cast


def escaped():
    a: 'List[\'Missing1\']' = []
    b: "Dict[str, \"Missing2\"]" = {}
    return a, b


def concatenated():
    c: ("Dict[str, "
        "Missing3]") = {}
    d: ("Optional["
        "List[int]]") = None
    return c, d


def nested():
    e: "List['Missing4' '']" = []
    f: "List[\"Missing5\"]" = []
    return e, f


def kept():
    g: 'Missing6["\d"]' = []
    h: r'Missing7\n' = []
    return g, h


def continued():
    i: 'Missing8[\
int]' = []
    j: """Missing9\n""" = 1
    k: """List[\nMissing10]""" = []
    return i, j, k


def casted(value):
    return cast('List[\'Missing11\']', value)


T = TypeVar('T', bound='Dict[str, \'Missing12\']')


class Held:
    first: '\tMissing13'
    second: '\nMissing14'
