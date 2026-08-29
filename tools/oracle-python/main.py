import ast
import io
import json
import os
import platform
import symtable
import sys
import token
import tokenize

FLAGS = (
    ('assigned', 'a'),
    ('free', 'f'),
    ('global', 'g'),
    ('imported', 'i'),
    ('local', 'l'),
    ('parameter', 'p'),
)

def line_starts(source):
    starts = [0]
    offset = 0
    length = len(source)

    while offset < length:
        byte = source[offset]

        if byte == 0x0D:
            offset += 2 if offset + 1 < length and source[offset + 1] == 0x0A else 1
            starts.append(offset)

            continue

        if byte == 0x0A:
            offset += 1
            starts.append(offset)

            continue

        offset += 1

    return starts

def offset_of(starts, length, line, column):
    if line is None or column is None:
        return None

    index = line - 1

    if index < 0 or index >= len(starts):
        return None

    return min(starts[index] + column, length)

def walk_ast(tree, starts, length):
    rows = []
    stack = [tree]

    while stack:
        node = stack.pop()
        start = offset_of(starts, length, getattr(node, 'lineno', None), getattr(node, 'col_offset', None))
        end = offset_of(starts, length, getattr(node, 'end_lineno', None), getattr(node, 'end_col_offset', None))

        if isinstance(node, ast.Module):
            rows.append(['Module', 0, length])
        elif start is not None and end is not None:
            rows.append([type(node).__name__, start, end])

        stack.extend(reversed(list(ast.iter_child_nodes(node))))

    return rows

def walk_scopes(table):
    rows = []
    stack = [table]

    while stack:
        scope = stack.pop()
        symbols = []

        named = scope.get_name() == 'top' and scope.get_type() != 'module'

        for symbol in sorted(scope.get_symbols(), key=lambda held: held.get_name()):
            letters = ''.join(
                letter
                for name, letter in FLAGS
                if getattr(symbol, 'is_' + name)()
            )

            if named and 'l' in letters:
                letters = letters.replace('g', '')

            symbols.append(f'{symbol.get_name()}:{letters}')

        rows.append([
            scope.get_type(),
            scope.get_name(),
            scope.get_lineno(),
            ','.join(symbols),
        ])

        stack.extend(reversed(scope.get_children()))

    rows.sort()

    return rows

def walk_symtable(table):
    rows = []
    stack = [table]

    while stack:
        scope = stack.pop()
        symbols = []

        for symbol in sorted(scope.get_symbols(), key=lambda held: held.get_name()):
            symbols.append([
                symbol.get_name(),
                {
                    'assigned': symbol.is_assigned(),
                    'free': symbol.is_free(),
                    'global': symbol.is_global(),
                    'imported': symbol.is_imported(),
                    'local': symbol.is_local(),
                    'parameter': symbol.is_parameter(),
                },
            ])

        rows.append({
            'line': scope.get_lineno(),
            'name': scope.get_name(),
            'symbols': symbols,
            'type': scope.get_type(),
        })

        stack.extend(reversed(scope.get_children()))

    return rows

def walk_tokens(text, starts, length):
    rows = []
    reader = io.StringIO(text).readline
    lines = text.splitlines(keepends=True)

    def offset(line, column):
        index = line - 1

        if index < 0 or index >= len(starts):
            return None

        prefix = lines[index][:column] if index < len(lines) else ''

        return min(starts[index] + len(prefix.encode('utf-8')), length)

    try:
        for held in tokenize.generate_tokens(reader):
            start = offset(held.start[0], held.start[1])
            end = offset(held.end[0], held.end[1])

            if start is None or end is None:
                continue

            rows.append([token.tok_name[held.type], start, end])
    except (IndentationError, SyntaxError, tokenize.TokenError):
        return rows

    return rows

def dump(source, path):
    text = source.decode('utf-8')
    starts = line_starts(source)
    length = len(source)
    tree = ast.parse(source, filename=path)

    return {
        'ast': walk_ast(tree, starts, length),
        'path': path,
        'scopes': walk_scopes(symtable.symtable(text, path, 'exec')),
        'symtable': walk_symtable(symtable.symtable(text, path, 'exec')),
        'tokens': walk_tokens(text, starts, length),
        'version': platform.python_version(),
    }

def sources(root):
    found = []

    for directory, _, names in os.walk(root, followlinks=True):
        for name in sorted(names):
            if not name.endswith('.py'):
                continue

            path = os.path.join(directory, name)
            found.append((os.path.relpath(path, root).replace(os.sep, '/'), path))

    found.sort()

    return found

def main(argv):
    if len(argv) != 3:
        print('usage: dump.py <source root> <destination root>', file=sys.stderr)

        return 2

    root = argv[1]
    destination = argv[2]
    skipped = []

    for relative, path in sources(root):
        with open(path, 'rb') as handle:
            source = handle.read()

        try:
            dumped = dump(source, relative)
        except (IndentationError, SyntaxError, UnicodeDecodeError, ValueError) as error:
            skipped.append((relative, type(error).__name__))

            continue

        target = os.path.join(destination, relative + '.json')
        os.makedirs(os.path.dirname(target), exist_ok=True)

        with open(target, 'w', encoding='utf-8') as handle:
            json.dump(
                dumped,
                handle,
                ensure_ascii=False,
                separators=(',', ':'),
                sort_keys=True,
            )
            handle.write('\n')

    for relative, reason in skipped:
        print(f'skipped {relative} ({reason})', file=sys.stderr)

    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv))
