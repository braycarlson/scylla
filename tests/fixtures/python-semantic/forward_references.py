from __future__ import annotations

from typing import TYPE_CHECKING, cast

if TYPE_CHECKING:
    from collections.abc import Sequence
    from decimal import Decimal
    from fractions import Fraction


def array(data):
    from decimal import Decimal
    from fractions import Fraction

    result = cast("Decimal | Fraction", data)
    return result


def other(data):
    import Sequence

    held: "Sequence" = data
    return held


def local_annotation(data):
    from fractions import Fraction

    held: Fraction = data
    return held


class Holder:
    Sequence = list

    def method(self, data: "Sequence") -> None:
        return None


def unbound():
    from json import dumps

    value: "dumps" = 1
    return value


dumps = 1
del dumps
