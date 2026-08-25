import os
import os.path
import numpy as np

from collections import OrderedDict as OD
from . import sibling
from ..pkg import thing


def local():
    return 1


print(os.path.join("a"))
print(np.array([]))
print(OD.fromkeys([]))
print(sibling.value)
print(thing.value)
print(local.__doc__)
print(len.__doc__)
