import json
import os
import re
import signal
import subprocess
import sys

KEYWORDS = frozenset(
    """
    addrspace align allowzero and anyframe anytype asm async await break callconv catch
    comptime const continue defer else enum errdefer error export extern fn for if inline
    linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct
    suspend switch test threadlocal try union unreachable usingnamespace var volatile while
    """.split()
)

IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

SECONDS_MAX = 20

DECLARED = re.compile(r"^(\s*)(?:pub\s+)?(?:const|var)\s+([A-Za-z_][A-Za-z0-9_]*)")
BINDER = re.compile(r"\b(?:const|var)\s+[A-Za-z_]")

def pin(root):
    with open(os.path.join(root, "PIN"), encoding="utf-8") as held:
        return held.read().strip()

def version():
    outcome = subprocess.run(["zls", "--version"], capture_output=True, text=True, check=False)

    return outcome.stdout.strip()

def spots(text):
    found = []
    offset = 0
    length = len(text)

    while offset < length:
        byte = text[offset]

        if byte == "/" and text.startswith("//", offset):
            stop = text.find("\n", offset)
            offset = length if stop < 0 else stop

            continue

        if byte == "\\" and text.startswith("\\\\", offset):
            stop = text.find("\n", offset)
            offset = length if stop < 0 else stop

            continue

        if byte in ('"', "'"):
            cursor = offset + 1

            while cursor < length and text[cursor] != byte:
                cursor += 2 if text[cursor] == "\\" else 1

            offset = cursor + 1

            continue

        if byte == "@" and offset + 1 < length and text[offset + 1] == '"':
            cursor = offset + 2

            while cursor < length and text[cursor] != '"':
                cursor += 2 if text[cursor] == "\\" else 1

            offset = cursor + 1

            continue

        match = IDENTIFIER.match(text, offset)

        if match is None:
            offset += 1

            continue

        labelled = match.end() < length and text[match.end()] == ":"
        broken = match.start() > 0 and text[match.start() - 1] == ":"

        if match.group(0) not in KEYWORDS and not labelled and not broken:
            found.append(match.start())

        offset = match.end()

    return found

class Stalled(Exception):
    pass

def ring(number, frame):
    raise Stalled

class Client:
    def __init__(self, root):
        self.proc = subprocess.Popen(
            ["zls"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        self.next_id = 1

        self.send(
            {
                "jsonrpc": "2.0",
                "id": 0,
                "method": "initialize",
                "params": {
                    "processId": os.getpid(),
                    "rootUri": "file://" + root,
                    "capabilities": {
                        "textDocument": {"definition": {"linkSupport": True}},
                    },
                },
            }
        )
        self.await_id(0)
        self.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

    def send(self, payload):
        body = json.dumps(payload).encode()

        self.proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        self.proc.stdin.flush()

    def read(self):
        length = 0

        while True:
            line = self.proc.stdout.readline()

            if not line:
                return None

            if line in (b"\r\n", b"\n"):
                break

            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":")[1])

        return json.loads(self.proc.stdout.read(length)) if length else None

    def await_id(self, wanted):
        for _ in range(512):
            held = self.read()

            if held is None:
                return None

            if held.get("id") == wanted:
                return held

        return None

    def request(self, method, params):
        held = self.next_id
        self.next_id += 1

        self.send({"jsonrpc": "2.0", "id": held, "method": method, "params": params})

        return self.await_id(held)

    def open(self, uri, text):
        self.send(
            {
                "jsonrpc": "2.0",
                "method": "textDocument/didOpen",
                "params": {
                    "textDocument": {
                        "uri": uri,
                        "languageId": "zig",
                        "version": 1,
                        "text": text,
                    }
                },
            }
        )

    def close(self, uri):
        self.send(
            {
                "jsonrpc": "2.0",
                "method": "textDocument/didClose",
                "params": {"textDocument": {"uri": uri}},
            }
        )

class Places:
    def __init__(self, text):
        self.text = text
        self.starts = [0]

        for index, byte in enumerate(text):
            if byte == "\n":
                self.starts.append(index + 1)

    def position_of(self, offset):
        low = 0
        high = len(self.starts) - 1

        while low < high:
            middle = (low + high + 1) // 2

            if self.starts[middle] <= offset:
                low = middle
            else:
                high = middle - 1

        prefix = self.text[self.starts[low] : offset]

        return low, len(prefix.encode("utf-16-le")) // 2

    def offset_of(self, line, character):
        if line >= len(self.starts):
            return None

        start = self.starts[line]
        stop = self.text.find("\n", start)
        stop = len(self.text) if stop < 0 else stop
        held = self.text[start:stop].encode("utf-16-le")
        prefix = held[: character * 2].decode("utf-16-le", "ignore")

        return start + len(prefix)

    def bytes_of(self, offset):
        return len(self.text[:offset].encode("utf-8"))

    def named(self, offset):
        start = self.text.rfind("\n", 0, offset) + 1
        stop = self.text.find("\n", offset)
        stop = len(self.text) if stop < 0 else stop
        line = self.text[start:stop]
        match = DECLARED.match(line)

        if match is None:
            return offset

        if len(BINDER.findall(line)) != 1:
            return offset

        equals = line.find("=")

        if equals < 0 or offset - start <= equals:
            return offset

        return start + match.start(2)

def sources(root):
    found = []

    for directory, _, names in os.walk(root, followlinks=True):
        for name in names:
            if name.endswith(".zig"):
                path = os.path.join(directory, name)
                found.append((os.path.relpath(path, root).replace(os.sep, "/"), path))

    found.sort()

    return found

def collect(client, path, text):
    uri = "file://" + os.path.abspath(path)
    places = Places(text)

    client.open(uri, text)

    rows = []

    for offset in spots(text):
        line, character = places.position_of(offset)
        held = client.request(
            "textDocument/definition",
            {
                "textDocument": {"uri": uri},
                "position": {"line": line, "character": character},
            },
        )

        if held is None:
            continue

        result = held.get("result")

        if not result:
            continue

        if isinstance(result, dict):
            result = [result]

        first = result[0]
        target = first.get("targetUri") or first.get("uri")
        selection = first.get("targetSelectionRange") or first.get("range") or {}
        start = selection.get("start")

        if target is None or start is None:
            continue

        if target != uri:
            rows.append([places.bytes_of(offset), -1])

            continue

        landed = places.offset_of(start["line"], start["character"])

        if landed is None:
            continue

        landed = places.named(landed)

        rows.append([places.bytes_of(offset), places.bytes_of(landed)])

    client.close(uri)
    rows.sort()

    return rows

def main():
    if len(sys.argv) != 3:
        print("usage: main.py <source-root> <destination>", file=sys.stderr)

        return 2

    root = os.path.dirname(os.path.abspath(__file__))
    wanted = pin(root)
    held = version()

    if wanted not in held:
        print(f"zls is {held or 'missing'} and the pin is {wanted}", file=sys.stderr)

        return 2

    source_root = os.path.abspath(sys.argv[1])
    destination = os.path.abspath(sys.argv[2])
    found = sources(source_root)

    if not found:
        print(f"no sources under {source_root}", file=sys.stderr)

        return 1

    client = Client(source_root)
    written = 0
    broken = 0

    for name, path in found:
        try:
            with open(path, encoding="utf-8") as source:
                text = source.read()
        except (OSError, UnicodeDecodeError):
            text = None

        if text is None:
            rows = []
            failed = True
            broken += 1
        else:
            signal.signal(signal.SIGALRM, ring)
            signal.alarm(SECONDS_MAX)

            try:
                rows = collect(client, path, text)
                failed = False
            except Stalled:
                client.proc.kill()
                client = Client(source_root)
                rows = []
                failed = True
                broken += 1
            finally:
                signal.alarm(0)

        target = os.path.join(destination, f"{name}.json")

        os.makedirs(os.path.dirname(target), exist_ok=True)

        with open(target, "w", encoding="utf-8") as out:
            json.dump({"zls": wanted, "broken": failed, "rows": rows}, out, separators=(",", ":"))
            out.write("\n")

        written += 1

    client.proc.kill()
    print(f"wrote {written} files for zls {wanted}, {broken} broken")

    return 0

if __name__ == "__main__":
    raise SystemExit(main())
