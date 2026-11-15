from typing import Annotated, Optional, Union, List
import typing
import typing as t


class Field:
    def __init__(self, *args, **kwargs): ...


a: Annotated[int, 'm1', Field(alias='m2', d={'m3': 'm4'})]
b: Annotated['U1', 'm5']
c: Annotated[Annotated['U2', 'm6'], Field()]
d: Optional[Field('m7')]
e: typing.Annotated['U3', 'm8']
f: t.List['U4']
g: List[Annotated[int, Field(x=lambda v: v + 'm9')]]
h: 'Annotated[int, Field(alias="m10")]'
i: Union['U5', Field('m11')]
