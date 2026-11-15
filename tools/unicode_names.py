import sys
import unicodedata

ALGORITHMIC = ('CJK UNIFIED IDEOGRAPH-', 'HANGUL SYLLABLE ')
SCALAR_MAX = 0x10FFFF


def aliases_of(path: str) -> list[str]:
    if not path:
        message = 'aliases_of needs the path of NameAliases.txt'
        raise ValueError(message)

    aliases = []

    with open(path, encoding='utf-8') as held:
        for line in held:
            line = line.strip()

            if not line:
                continue

            if line.startswith('#'):
                continue

            aliases.append(line.split(';')[1])

    return aliases


def explicit() -> list[str]:
    names = []

    for scalar in range(SCALAR_MAX + 1):
        name = unicodedata.name(chr(scalar), None)

        if name is None:
            continue

        if name.startswith(ALGORITHMIC):
            continue

        names.append(name)

    return names


def main() -> None:
    names = sorted(set(explicit() + aliases_of(sys.argv[1])))

    print(f'Unicode {unicodedata.unidata_version}, {len(names)} names', file=sys.stderr)
    sys.stdout.write(''.join(name + '\n' for name in names))


main()
