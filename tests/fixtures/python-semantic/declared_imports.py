import os
import sys


def determine():
    global qtpy, PyQt5

    try:
        import qtpy
    except ImportError:
        try:
            import PyQt5
        except ImportError:
            pass


def rebinds():
    global os
    import os


def reads():
    global sys
    import sys

    return sys


def enclosing():
    held = 1

    def inner():
        nonlocal held
        import held

    return inner


def returning():
    seen = 1

    def inner():
        nonlocal seen
        import seen

        return seen

    return inner


def declared_first():
    global json

    return json


global json
import json
