import os
os = 1

def f(): pass
f = 2

class C: pass
C = 3

x = 1
x = 2

def g(): pass
g: int = 3

def h(): pass
h += 1

def k(): pass
(k := 5)

def m(): pass
for m in range(3): pass

def n(): pass
with open('x') as n: pass

def p(): pass
q, p = 1, 2


class D:
    def ser_x(self): pass

    ser_x = staticmethod(ser_x)

    def ser_y(self): pass

    ser_y = 1


x2 = lambda: 1
x2 = lambda: 2

y = 1
def y(): pass

z = 1
class z: pass

w = 1
with open('f') as w: pass

def v(): pass
try:
    pass
except Exception as v:
    pass

def u(): pass
match 1:
    case u:
        pass

def t(): pass
type t = int

import s
from s import s

import r.q
import r.q

import p.o
import p.n

def _m(): pass
_m = 1

import _n
_n = 1

import k
del k
import k

def g1():
    def l(): pass
    l = 1
    import os
    return l, os

import os


def f():
    import tqdm.auto as tqdm

    return tqdm


def g():
    import a.b as a

    return a


import c.d as c
import e.f as e2

print(c, e2)
import os
os += 1


def f():
    import sys
    sys += 1


def h(): pass
h += 1
