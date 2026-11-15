import collections.abc
import sys
import unicodedata

SCALAR_MAX = 0x10FFFF


def derived_of(path: str, name: str) -> set[int]:
    if not path:
        message = 'derived_of needs the path of DerivedCoreProperties.txt'
        raise ValueError(message)

    if not name:
        message = 'derived_of needs a property name'
        raise ValueError(message)

    scalars = set()

    with open(path, encoding='utf-8') as held:
        header = held.readline()
        version = unicodedata.unidata_version

        assert version in header, f'{path} is not Unicode {version}'

        for line in held:
            fields = line.split('#')[0].split(';')

            if len(fields) != 2:
                continue

            if fields[1].strip() != name:
                continue

            bounds = fields[0].strip().split('..')

            scalars.update(range(int(bounds[0], 16), int(bounds[-1], 16) + 1))

    return scalars


def ranges_of(holds: collections.abc.Callable[[int], bool]) -> list[tuple[int, int]]:
    ranges = []
    first = None

    for scalar in range(0x80, SCALAR_MAX + 1):
        if holds(scalar):
            if first is None:
                first = scalar

            continue

        if first is not None:
            ranges.append((first, scalar - 1))
            first = None

    if first is not None:
        ranges.append((first, SCALAR_MAX))

    return ranges


def beyond_xid(
    derived: set[int],
    is_xid: collections.abc.Callable[[int], bool],
) -> collections.abc.Callable[[int], bool]:
    if not derived:
        message = 'beyond_xid needs a non-empty derived property'
        raise ValueError(message)

    xid = {scalar for scalar in range(0x80, SCALAR_MAX + 1) if is_xid(scalar)}

    assert xid <= derived, 'an XID scalar is missing from its ID property'

    return (derived - xid).__contains__


def is_xid_start(scalar: int) -> bool:
    if scalar > SCALAR_MAX:
        message = f'{scalar:#x} is beyond the last Unicode scalar'
        raise ValueError(message)

    return chr(scalar).isidentifier()


def is_xid_continue(scalar: int) -> bool:
    if scalar > SCALAR_MAX:
        message = f'{scalar:#x} is beyond the last Unicode scalar'
        raise ValueError(message)

    text = 'a' + chr(scalar)
    return text.isidentifier()


def is_digit(scalar: int) -> bool:
    if scalar > SCALAR_MAX:
        message = f'{scalar:#x} is beyond the last Unicode scalar'
        raise ValueError(message)

    return unicodedata.category(chr(scalar)) == 'Nd'


def emit(name: str, ranges: list[tuple[int, int]]) -> None:
    if not name:
        message = 'emit needs a table name'
        raise ValueError(message)

    if not ranges:
        message = f'{name} has no ranges'
        raise ValueError(message)

    print(f'const {name} = [_]Range{{')

    for first, last in ranges:
        print(f'    .{{ .first = 0x{first:04x}, .last = 0x{last:04x} }},')

    print('};')
    print()


def main() -> None:
    id_continue = derived_of(sys.argv[1], 'ID_Continue')
    id_start = derived_of(sys.argv[1], 'ID_Start')

    print(f'// Unicode {unicodedata.unidata_version}', file=sys.stderr)
    emit('digit_ranges', ranges_of(is_digit))
    emit('id_continue_beyond_xid_ranges', ranges_of(beyond_xid(id_continue, is_xid_continue)))
    emit('id_start_beyond_xid_ranges', ranges_of(beyond_xid(id_start, is_xid_start)))
    emit('xid_continue_ranges', ranges_of(is_xid_continue))
    emit('xid_start_ranges', ranges_of(is_xid_start))


main()
