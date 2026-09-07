"""Diff scylla's token boundaries against each language's own tokenizer over the corpus."""

import argparse
import io
import json
import keyword
import os
import pathlib
import subprocess
import sys
import token as token_module
import tokenize

LANGUAGES = ('go', 'javascript', 'odin', 'python', 'rust', 'typescript', 'zig')

EXTENSIONS = {
    'go': ('.go',),
    'javascript': ('.js', '.jsx', '.mjs', '.cjs'),
    'odin': ('.odin',),
    'python': ('.py',),
    'rust': ('.rs',),
    'typescript': ('.cts', '.mts', '.ts', '.tsx'),
    'zig': ('.zig',),
}

STRUCTURAL = {'block-end', 'block-start', 'newline'}

SCRIPT_SUFFIXES = EXTENSIONS['javascript'] + EXTENSIONS['typescript']

STATEMENT_ENDS = {'go', 'odin', 'python'}

FOLDED: dict[str, str] = {}

WORDS = {'identifier', 'keyword'}

DROPPED = {'zig': {'comment'}}

FILE_BYTES_MAX = 1 << 20


class Token:
    __slots__ = ('kind', 'length', 'offset')

    def __init__(self, offset: int, length: int, kind: str) -> None:
        self.offset = offset
        self.length = length
        self.kind = kind

    def __repr__(self) -> str:
        return f'{self.offset}:{self.length} {self.kind}'


class Divergence:
    __slots__ = ('ours', 'path', 'theirs')

    def __init__(self, path: pathlib.Path, ours: Token | None, theirs: Token | None) -> None:
        self.path = path
        self.ours = ours
        self.theirs = theirs


def a_multi_character_operator(divergence: Divergence) -> bool:
    ours = divergence.ours
    theirs = divergence.theirs

    if ours is None or theirs is None:
        return False

    return ours.kind == 'punctuation' and theirs.kind == 'punctuation' and contains(theirs, ours)


def a_joined_operator(divergence: Divergence) -> bool:
    ours = divergence.ours
    theirs = divergence.theirs

    if ours is None or theirs is None:
        return False

    return ours.kind == 'punctuation' and theirs.kind == 'punctuation' and contains(ours, theirs)


def a_closure_bar(divergence: Divergence) -> bool:
    ours = divergence.ours
    theirs = divergence.theirs

    if ours is None or theirs is None:
        return False

    if ours.kind not in WORDS or theirs.kind != 'punctuation':
        return False

    same = ours.offset == theirs.offset and ours.length == theirs.length

    return same or contains(ours, theirs)


def contains(outer: Token, inner: Token) -> bool:
    return outer.offset <= inner.offset \
        and inner.offset + inner.length <= outer.offset + outer.length \
        and outer.length > inner.length


def a_raw_or_prefixed_literal(divergence: Divergence) -> bool:
    ours = divergence.ours
    theirs = divergence.theirs

    if ours is None or theirs is None:
        return False

    return {ours.kind, theirs.kind} <= {'string', 'number'} | WORDS \
        and ours.offset != theirs.offset \
        and abs(ours.offset - theirs.offset) <= 2


def a_byte_literal_prefix(divergence: Divergence) -> bool:
    ours = divergence.ours
    theirs = divergence.theirs

    if ours is None or theirs is None:
        return False

    return ours.kind in WORDS and theirs.kind == 'string' \
        and ours.offset == theirs.offset and ours.length < theirs.length


def a_raw_identifier(divergence: Divergence) -> bool:
    ours = divergence.ours
    theirs = divergence.theirs

    if ours is None or theirs is None:
        return False

    return theirs.kind in WORDS and ours.kind in WORDS | {'punctuation'} \
        and contains(theirs, ours)


def a_trailing_dot_float(divergence: Divergence) -> bool:
    ours = divergence.ours
    theirs = divergence.theirs

    if ours is None or theirs is None:
        return False

    return theirs.kind == 'number' and ours.kind in {'number', 'punctuation'} \
        and contains(theirs, ours)


def a_word_spelled_operator(divergence: Divergence) -> bool:
    ours = divergence.ours
    theirs = divergence.theirs

    if ours is None or theirs is None:
        return False

    return ours.kind == 'punctuation' and theirs.kind in WORDS \
        and ours.offset == theirs.offset and ours.length == theirs.length


ELEMENTS: dict[str, list['Token']] = {}

QUOTE_BYTES = b'"\'`'

SOURCES: dict[str, bytes] = {}

SPILLS: dict[str, int] = {}


def bytes_of(path: pathlib.Path) -> bytes:
    key = str(path)

    if key not in SOURCES:
        SOURCES[key] = path.read_bytes()

    return SOURCES[key]


def source_of(divergence: Divergence) -> bytes:
    return bytes_of(divergence.path)


def text_of(divergence: Divergence, token: Token | None) -> bytes:
    if token is None:
        return b''

    return source_of(divergence)[token.offset : token.offset + token.length]


def promoted(divergence: Divergence) -> bytes | None:
    ours = divergence.ours
    theirs = divergence.theirs

    if ours is None or theirs is None:
        return None

    if ours.kind != 'keyword' or theirs.kind != 'identifier':
        return None

    if (ours.offset, ours.length) != (theirs.offset, theirs.length):
        return None

    return text_of(divergence, ours)


ASSERTION_WORDS = (
    b'assert',
    b'ensure',
    b'expect',
    b'fail',
    b'invariant',
    b'panic',
    b'require',
    b'testing',
    b'unimplemented',
)


def an_assertion_name_keyword(divergence: Divergence) -> bool:
    word = promoted(divergence)

    if word is None:
        return False

    return any(marker in word for marker in ASSERTION_WORDS)


VALUE_WORDS = (b'False', b'None', b'Self', b'True', b'false', b'null', b'true', b'undefined')

TYPE_WORDS = (
    b'any',
    b'as',
    b'bigint',
    b'boolean',
    b'never',
    b'number',
    b'object',
    b'string',
    b'symbol',
    b'unknown',
    b'void',
)

CONTEXTUAL_WORDS = (
    b'asserts',
    b'async',
    b'catch',
    b'class',
    b'const',
    b'constructor',
    b'continue',
    b'declare',
    b'default',
    b'enum',
    b'from',
    b'function',
    b'get',
    b'in',
    b'infer',
    b'instanceof',
    b'is',
    b'keyof',
    b'match',
    b'module',
    b'out',
    b'override',
    b'private',
    b'protected',
    b'public',
    b'readonly',
    b'require',
    b'satisfies',
    b'set',
    b'this',
    b'type',
    b'unique',
    b'using',
    b'with',
)


def one_word(divergence: Divergence) -> bytes | None:
    ours = divergence.ours
    theirs = divergence.theirs

    if ours is None or theirs is None:
        return None

    if {ours.kind, theirs.kind} != WORDS:
        return None

    if (ours.offset, ours.length) != (theirs.offset, theirs.length):
        return None

    return text_of(divergence, ours)


def a_value_word_keyword(divergence: Divergence) -> bool:
    return one_word(divergence) in VALUE_WORDS


def a_type_word_keyword(divergence: Divergence) -> bool:
    return one_word(divergence) in TYPE_WORDS


def a_contextual_keyword(divergence: Divergence) -> bool:
    if one_word(divergence) in CONTEXTUAL_WORDS:
        return True

    return promoted(divergence) is not None and divergence.path.suffix in SCRIPT_SUFFIXES


def a_builtin_keyword(divergence: Divergence) -> bool:
    word = promoted(divergence)

    return word is not None and word.startswith(b'@')


RESERVED_WORDS = (b'gen', b'try')

RETIRED_WORDS = (b'anyframe', b'async', b'await', b'usingnamespace')


def demoted(divergence: Divergence) -> bytes | None:
    ours = divergence.ours
    theirs = divergence.theirs

    if ours is None or theirs is None:
        return None

    if ours.kind != 'identifier' or theirs.kind != 'keyword':
        return None

    if (ours.offset, ours.length) != (theirs.offset, theirs.length):
        return None

    return text_of(divergence, ours)


def a_reserved_keyword(divergence: Divergence) -> bool:
    return demoted(divergence) in RESERVED_WORDS


def a_retired_keyword(divergence: Divergence) -> bool:
    return demoted(divergence) in RETIRED_WORDS


def a_carriage_return_span(divergence: Divergence) -> bool:
    ours = divergence.ours
    theirs = divergence.theirs

    if ours is None or theirs is None:
        return False

    source = divergence.path.read_bytes()
    end = theirs.offset + theirs.length

    if end == 0 or end > len(source) or source[end - 1 : end] != b'\r':
        return False

    stop = end + (1 if source[end : end + 1] == b'\n' else 0)

    return theirs.offset <= ours.offset <= stop


def a_label_statement_end(divergence: Divergence) -> bool:
    ours = divergence.ours

    if ours is None or ours.kind != 'newline':
        return False

    source = divergence.path.read_bytes()
    start = source.rfind(b'\n', 0, ours.offset) + 1
    line = source[start : ours.offset]

    return any(head.rstrip().endswith(b':') for head in comment_heads(line))


def comment_heads(line: bytes) -> list[bytes]:
    heads = [line]

    for marker in (b'//', b'/*'):
        found = line.find(marker)

        while found != -1:
            heads.append(line[:found])
            found = line.find(marker, found + 1)

    return heads


def a_synthesized_statement_end(divergence: Divergence) -> bool:
    ours = divergence.ours

    return ours is not None and ours.kind == 'newline' and ours.length == 0


def a_jsx_text_run(divergence: Divergence) -> bool:
    return divergence.theirs is not None and divergence.theirs.kind == 'jsx-text'


def a_jsx_element_span(divergence: Divergence) -> bool:
    sited = divergence.ours if divergence.ours else divergence.theirs

    return any(
        element.offset <= sited.offset < element.offset + element.length
        for element in ELEMENTS.get(str(divergence.path), [])
    )


def a_jsx_text_spill(divergence: Divergence) -> bool:
    sited = divergence.ours if divergence.ours else divergence.theirs
    spill = SPILLS.get(str(divergence.path))

    return spill is not None and sited.offset >= spill


TRIPLE_QUOTES = (b'"""', b'```')


def a_triple_quoted_string(divergence: Divergence) -> bool:
    ours = divergence.ours
    theirs = divergence.theirs

    if ours is not None and ours.kind == 'string' and text_of(divergence, ours)[:3] in TRIPLE_QUOTES:
        return True

    if theirs is None or theirs.kind != 'string':
        return False

    source = source_of(divergence)
    windows = (
        source[theirs.offset - 2 : theirs.offset + 1],
        source[theirs.offset - 1 : theirs.offset + 2],
    )

    return any(window in TRIPLE_QUOTES for window in windows)


CLASSIFIERS = (
    an_assertion_name_keyword,
    a_value_word_keyword,
    a_type_word_keyword,
    a_contextual_keyword,
    a_retired_keyword,
    a_reserved_keyword,
    a_builtin_keyword,
    a_carriage_return_span,
    a_label_statement_end,
    a_synthesized_statement_end,
    a_jsx_text_run,
    a_jsx_element_span,
    a_jsx_text_spill,
    a_triple_quoted_string,
    a_multi_character_operator,
    a_joined_operator,
    a_closure_bar,
    a_byte_literal_prefix,
    a_raw_identifier,
    a_trailing_dot_float,
    a_word_spelled_operator,
    a_raw_or_prefixed_literal,
)


def scylla_tokens(
    binary: pathlib.Path,
    path: pathlib.Path,
    drop: set[str],
    structural: set[str],
) -> list[Token] | None:
    run = subprocess.run(
        [str(binary), 'tokens', str(path)],
        capture_output=True,
        check=False,
    )

    if run.returncode != 0:
        return None

    tokens = []

    for line in run.stdout.decode('utf-8', 'replace').splitlines():
        span, _, kind = line.partition(' ')
        offset, _, length = span.partition(':')
        coarse = kind.split(':', 1)[0]

        if coarse in structural or coarse in drop:
            continue

        tokens.append(Token(int(offset), int(length), FOLDED.get(coarse, coarse)))

    return tokens


def oracle_tokens(command: list[str], path: pathlib.Path, drop: set[str]) -> list[Token] | None:
    run = subprocess.run(command + [str(path)], capture_output=True, check=False)

    if run.returncode != 0:
        return None

    tokens = []
    elements = []

    for line in run.stdout.decode('utf-8', 'replace').splitlines():
        span, _, kind = line.partition(' ')
        offset, _, length = span.partition(':')

        if kind in drop:
            continue

        if kind == 'jsx-element':
            elements.append(Token(int(offset), int(length), kind))

            continue

        tokens.append(Token(int(offset), int(length), kind))

    ELEMENTS[str(path)] = elements
    SPILLS.pop(str(path), None)

    for token in tokens:
        if token.kind != 'jsx-text':
            continue

        text = bytes_of(path)[token.offset : token.offset + token.length]

        if any(byte in QUOTE_BYTES for byte in text):
            SPILLS[str(path)] = token.offset

            break

    return tokens


def newer_than_the_interpreter(path: pathlib.Path) -> bool:
    parts = path.name.split('.')

    if len(parts) < 4:
        return False

    major, minor = parts[-3], parts[-2]

    if not major.isdigit() or not minor.isdigit():
        return False

    return (int(major), int(minor)) > sys.version_info[:2]


def python_tokens(path: pathlib.Path) -> list[Token] | None:
    if newer_than_the_interpreter(path):
        return None

    source = path.read_bytes()
    lines = source.split(b'\n')
    starts = []
    running = 0

    for line in lines:
        starts.append(running)
        running += len(line) + 1

    tokens = []
    depth = 0
    opened = 0

    def offset_of(row: int, column: int) -> int | None:
        if row - 1 >= len(starts):
            return None

        return starts[row - 1] + len(lines[row - 1].decode('utf-8', 'replace')[:column].encode())

    try:
        for entry in tokenize.tokenize(io.BytesIO(source).readline):
            start = offset_of(*entry.start)
            end = offset_of(*entry.end)

            if start is None or end is None:
                continue

            if entry.type == getattr(token_module, 'FSTRING_START', -1):
                if depth == 0:
                    opened = start

                depth += 1

                continue

            if entry.type == getattr(token_module, 'FSTRING_END', -2):
                depth -= 1

                if depth == 0:
                    tokens.append(Token(opened, end - opened, 'string'))

                continue

            if depth > 0:
                continue

            kind = python_class(entry.type, entry.string)

            if kind is None:
                continue

            if kind == 'newline':
                if start >= len(source):
                    continue

                end = start + (2 if source[start : start + 2] == b'\r\n' else 1)

            tokens.append(Token(start, end - start, kind))
    except (tokenize.TokenError, IndentationError, SyntaxError, UnicodeDecodeError):
        return None

    return tokens


def python_class(kind: int, text: str) -> str | None:
    if kind == token_module.NAME:
        return 'keyword' if keyword.iskeyword(text) else 'identifier'

    if kind == token_module.NUMBER:
        return 'number'

    if kind == token_module.STRING:
        return 'string'

    if kind == token_module.COMMENT:
        return 'comment'

    if kind == token_module.OP:
        return 'punctuation'

    if kind == token_module.NEWLINE:
        return 'newline'

    return None


def compared(ours: list[Token], theirs: list[Token], path: pathlib.Path) -> list[Divergence]:
    divergences = []
    left_index = 0
    right_index = 0

    while left_index < len(ours) and right_index < len(theirs):
        left = ours[left_index]
        right = theirs[right_index]

        if (left.offset, left.length, left.kind) == (right.offset, right.length, right.kind):
            left_index += 1
            right_index += 1

            continue

        divergences.append(Divergence(path, left, right))

        left_end = left.offset + left.length
        right_end = right.offset + right.length

        if left_end < right_end:
            left_index += 1
        elif right_end < left_end:
            right_index += 1
        else:
            left_index += 1
            right_index += 1

    while left_index < len(ours):
        divergences.append(Divergence(path, ours[left_index], None))
        left_index += 1

    while right_index < len(theirs):
        divergences.append(Divergence(path, None, theirs[right_index]))
        right_index += 1

    return divergences


def files_of(root: pathlib.Path, language: str) -> tuple[list[pathlib.Path], int]:
    found = []
    skipped = 0

    for suffix in EXTENSIONS[language]:
        for path in sorted(root.rglob(f'*{suffix}')):
            if not path.is_file() or path.stat().st_size >= FILE_BYTES_MAX:
                skipped += 1

                continue

            held = path.read_bytes()

            if b'\x1b' in held or held.startswith(b'<?xml'):
                skipped += 1

                continue

            found.append(path)

    return found, skipped


def classified(divergence: Divergence) -> str | None:
    for classifier in CLASSIFIERS:
        if classifier(divergence):
            return classifier.__name__

    return None


def line_behind(path: pathlib.Path, offset: int) -> str:
    source = path.read_bytes()

    if offset >= len(source):
        return ''

    start = source.rfind(b'\n', 0, offset) + 1
    end = source.find(b'\n', offset)

    if end == -1:
        end = len(source)

    return source[start:end].decode('utf-8', 'replace').strip()


def checkouts_of(
    roots: list[pathlib.Path],
    corpora: list[str] | None,
) -> list[pathlib.Path]:
    every = []

    for root in roots:
        every.extend(sorted(path for path in root.iterdir() if path.is_dir()))

    if corpora is None:
        return every

    named = set(corpora)
    chosen = [path for path in every if path.name in named]
    missing = named - {path.name for path in chosen}

    if missing:
        roots_text = ', '.join(str(root) for root in roots)

        print(f'missing from {roots_text}: {", ".join(sorted(missing))}')
        raise SystemExit(1)

    return chosen


def token_pair(
    binary: pathlib.Path,
    path: pathlib.Path,
    language: str,
    oracles: dict[str, list[str]],
    structural: set[str],
) -> tuple[list[Token] | None, list[Token] | None]:
    drop = DROPPED.get(language, set())
    ours = scylla_tokens(binary, path, drop, structural)

    if language == 'python':
        return ours, python_tokens(path)

    return ours, oracle_tokens(oracles[language], path, drop)


def entry_of(divergence: Divergence, path: pathlib.Path) -> dict:
    sited = divergence.ours if divergence.ours else divergence.theirs

    return {
        'path': str(path),
        'ours': repr(divergence.ours),
        'theirs': repr(divergence.theirs),
        'line': line_behind(path, sited.offset),
    }


def tallied(
    divergences: list[Divergence],
    path: pathlib.Path,
    counts: dict[str, int],
    unclassified: list[dict],
    limit: int,
) -> bool:
    dirty = False

    for divergence in divergences:
        name = classified(divergence)

        if name is not None:
            counts[name] = counts.get(name, 0) + 1

            continue

        dirty = True

        if len(unclassified) < limit:
            unclassified.append(entry_of(divergence, path))

    return dirty


def report_of(
    binary: pathlib.Path,
    roots: list[pathlib.Path],
    languages: list[str],
    oracles: dict[str, list[str]],
    limit: int,
    corpora: list[str] | None = None,
) -> dict:
    report = {}

    for language in languages:
        counts: dict[str, int] = {}
        unclassified = []
        compared_files = 0
        clean_files = 0
        skipped_files = 0

        structural = STRUCTURAL - ({'newline'} if language in STATEMENT_ENDS else set())

        for checkout in checkouts_of(roots, corpora):
            paths, skipped = files_of(checkout, language)
            skipped_files += skipped

            for path in paths:
                ours, theirs = token_pair(binary, path, language, oracles, structural)

                if ours is None or theirs is None:
                    continue

                compared_files += 1
                dirty = tallied(compared(ours, theirs, path), path, counts, unclassified, limit)

                if not dirty:
                    clean_files += 1

        report[language] = {
            'files': compared_files,
            'skipped': skipped_files,
            'clean': clean_files,
            'classified': counts,
            'unclassified': len(unclassified),
            'entries': unclassified,
        }

    return report


def printed(report: dict) -> None:
    for language, entry in report.items():
        print(
            f'{language}: {entry["files"]} files compared, '
            f'{entry["clean"]} without an unclassified divergence, '
            f'{entry["skipped"]} skipped as oversized or not plain source'
        )

        for name, count in sorted(entry['classified'].items()):
            print(f'  {name}: {count}')

        if entry['unclassified']:
            print(f'  unclassified: {entry["unclassified"]}')

        for item in entry['entries']:
            print(f'    {item["path"]}')
            print(f'      scylla {item["ours"]} oracle {item["theirs"]}')
            print(f'      {item["line"]}')


def checked(report: dict, ledger: pathlib.Path) -> int:
    recorded = json.loads(ledger.read_text(encoding='utf-8'))
    failures = 0

    for language, entry in report.items():
        expected = recorded.get(language)

        if expected is None:
            print(f'{language} is not recorded in {ledger}')
            failures += 1

            continue

        if entry['unclassified'] > 0:
            print(f'{language} carries {entry["unclassified"]} unclassified divergences')
            failures += 1

        for name, count in sorted(entry['classified'].items()):
            allowed = expected['classified'].get(name, 0)

            if count > allowed:
                print(f'{language} {name} grew from {allowed} to {count}')
                failures += 1

    return failures


def written(report: dict, ledger: pathlib.Path) -> None:
    recorded = {
        language: {
            'files': entry['files'],
            'classified': entry['classified'],
            'unclassified': entry['unclassified'],
        }
        for language, entry in report.items()
    }

    ledger.write_text(json.dumps(recorded, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)

    parser.add_argument('--binary', default='tools/runner/target/release/runner')
    parser.add_argument('--corpus-root', action='append')
    parser.add_argument('--language', default='all')

    parser.add_argument(
        '--corpus',
        action='append',
        help='a corpus checkout to compare; repeatable. Without it every checkout '
        'on disk is compared, which makes the ledger unreproducible.',
    )

    parser.add_argument('--limit', type=int, default=20)
    parser.add_argument('--check')
    parser.add_argument('--ledger')

    arguments = parser.parse_args()
    languages = list(LANGUAGES) if arguments.language == 'all' else [arguments.language]
    roots = [
        pathlib.Path(name)
        for name in arguments.corpus_root or [os.environ.get('SCYLLA_CORPUS', 'corpus/sources')]
    ]

    for root in roots:
        if not root.is_dir():
            print(f'{root} is not a directory; run corpus/fetch.sh first')

            return 2

    oracles = {
        'go': ['tools/oracle-lex-go/target/oracle-lex-go'],
        'javascript': ['node', 'tools/oracle-lex-js/main.js'],
        'odin': ['tools/oracle-lex-odin/target/oracle-lex-odin'],
        'rust': ['tools/oracle-lex-rust/target/release/oracle-lex-rust'],
        'typescript': ['node', 'tools/oracle-lex-js/main.js'],
        'zig': ['tools/oracle-lex-zig/zig-out/bin/oracle-lex-zig'],
    }

    for language in list(languages):
        if language == 'python':
            continue

        probe = oracles[language][-1] if oracles[language][0] == 'node' else oracles[language][0]

        if not pathlib.Path(probe).is_file():
            print(f'{language}: the oracle is not built; skipping')
            languages.remove(language)

    report = report_of(
        pathlib.Path(arguments.binary),
        roots,
        languages,
        oracles,
        arguments.limit,
        arguments.corpus,
    )

    printed(report)

    if arguments.ledger:
        written(report, pathlib.Path(arguments.ledger))

    if arguments.check:
        return 1 if checked(report, pathlib.Path(arguments.check)) else 0

    return 0


if __name__ == '__main__':
    sys.exit(main())
