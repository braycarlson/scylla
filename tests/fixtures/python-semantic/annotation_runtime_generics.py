from typing import Annotated, List, NamedTuple, NewType, Optional, TypedDict, TypeVar, Union, cast
from typing_extensions import TypeAliasType


def runtime():
    A = Union[str, 'Later1', 'Later2']
    B = list['Later3']
    C = Annotated['Later4', 3]
    D = Optional['Missing1']
    E = dict['key1', 'Missing2']
    Later1 = int
    Later2 = int
    Later3 = int
    Later4 = int
    return A, B, C, D, E


class Model:
    pass


M = Model[list['Undefined1']]
T = TypeVar('T', 'Missing3', bound='Missing4', default='Missing5', covariant='m1')
N = NewType('N', 'Missing6')
X = TypeAliasType('X', 'Missing7', type_params=())
Y = cast('Missing8', 1)
P = NamedTuple('P', [('a', 'Missing9'), ('b', int)])
R = TypedDict('R', {'k': 'Missing10'}, total='m2')
S = TypedDict('S', k='Missing11')
type Z = 'Missing12'
V = Model('m3')


def shadow():
    list = [1]
    return list['x']


class G(List['Missing13']):
    pass
