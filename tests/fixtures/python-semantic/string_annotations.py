from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections import OrderedDict
    from decimal import Decimal

import json


def read(held: "OrderedDict[str, int]") -> "json.JSONDecoder":
    return held


value: "Decimal" = 1
