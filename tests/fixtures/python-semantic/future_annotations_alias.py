from __future__ import annotations as _annotations


class Table:
    def sorted(self) -> Table:
        return self

    def merged(self, other: Missing) -> Table:
        return other
