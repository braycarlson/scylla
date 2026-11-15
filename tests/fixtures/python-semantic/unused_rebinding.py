import os
import sys
from collections import OrderedDict, deque
from json import dumps, loads

__all__ = (os.__all__ + ["OrderedDict", "dumps"])
__all__ += list(("deque",))


def hidden():
    __traceback_hide__ = True
    __tracebackhide__ = True
    __traceback_info__ = 1
    _dummy = 2
    _trailing_ = 3
    __ = 4
    return None


def rebound(path):
    handle = open(path)
    print(handle)
    del handle
    handle = open(path)


def caught():
    try:
        pass
    except ValueError as __error__:
        pass
    except KeyError as _error:
        pass
