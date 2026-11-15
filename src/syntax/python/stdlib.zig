const std = @import("std");
const assert = std.debug.assert;

pub const PythonVersion = enum {
    py38,
    py39,
    py310,
    py311,
    py312,
    py313,
    py314,

    pub fn at_least(version: PythonVersion, other: PythonVersion) bool {
        const result = version.minor() >= other.minor();

        assert(result == (@backingInt(version) >= @backingInt(other)));
        if (version == other) assert(result);

        return result;
    }

    pub fn minor(version: PythonVersion) u8 {
        const result: u8 = switch (version) {
            .py38 => 8,
            .py39 => 9,
            .py310 => 10,
            .py311 => 11,
            .py312 => 12,
            .py313 => 13,
            .py314 => 14,
        };

        assert(result >= 8);
        assert(result == @as(u8, @backingInt(version)) + 8);

        return result;
    }

    pub fn name(version: PythonVersion) []const u8 {
        const result: []const u8 = switch (version) {
            .py38 => "3.8",
            .py39 => "3.9",
            .py310 => "3.10",
            .py311 => "3.11",
            .py312 => "3.12",
            .py313 => "3.13",
            .py314 => "3.14",
        };

        assert(std.mem.startsWith(u8, result, "3."));
        assert(result.len >= 3);

        return result;
    }
};

pub const builtins: []const []const u8 = &.{
    "ArithmeticError",
    "AssertionError",
    "AttributeError",
    "BaseException",
    "BlockingIOError",
    "BrokenPipeError",
    "BufferError",
    "BytesWarning",
    "ChildProcessError",
    "ConnectionAbortedError",
    "ConnectionError",
    "ConnectionRefusedError",
    "ConnectionResetError",
    "DeprecationWarning",
    "EOFError",
    "Ellipsis",
    "EnvironmentError",
    "Exception",
    "False",
    "FileExistsError",
    "FileNotFoundError",
    "FloatingPointError",
    "FutureWarning",
    "GeneratorExit",
    "IOError",
    "ImportError",
    "ImportWarning",
    "IndentationError",
    "IndexError",
    "InterruptedError",
    "IsADirectoryError",
    "KeyError",
    "KeyboardInterrupt",
    "LookupError",
    "MemoryError",
    "ModuleNotFoundError",
    "NameError",
    "None",
    "NotADirectoryError",
    "NotImplemented",
    "NotImplementedError",
    "OSError",
    "OverflowError",
    "PendingDeprecationWarning",
    "PermissionError",
    "ProcessLookupError",
    "RecursionError",
    "ReferenceError",
    "ResourceWarning",
    "RuntimeError",
    "RuntimeWarning",
    "StopAsyncIteration",
    "StopIteration",
    "SyntaxError",
    "SyntaxWarning",
    "SystemError",
    "SystemExit",
    "TabError",
    "TimeoutError",
    "True",
    "TypeError",
    "UnboundLocalError",
    "UnicodeDecodeError",
    "UnicodeEncodeError",
    "UnicodeError",
    "UnicodeTranslateError",
    "UnicodeWarning",
    "UserWarning",
    "ValueError",
    "Warning",
    "ZeroDivisionError",
    "__build_class__",
    "__debug__",
    "__doc__",
    "__import__",
    "__loader__",
    "__name__",
    "__package__",
    "__spec__",
    "abs",
    "all",
    "any",
    "ascii",
    "bin",
    "bool",
    "breakpoint",
    "bytearray",
    "bytes",
    "callable",
    "chr",
    "classmethod",
    "compile",
    "complex",
    "copyright",
    "credits",
    "delattr",
    "dict",
    "dir",
    "divmod",
    "enumerate",
    "eval",
    "exec",
    "exit",
    "filter",
    "float",
    "format",
    "frozenset",
    "getattr",
    "globals",
    "hasattr",
    "hash",
    "help",
    "hex",
    "id",
    "input",
    "int",
    "isinstance",
    "issubclass",
    "iter",
    "len",
    "license",
    "list",
    "locals",
    "map",
    "max",
    "memoryview",
    "min",
    "next",
    "object",
    "oct",
    "open",
    "ord",
    "pow",
    "print",
    "property",
    "quit",
    "range",
    "repr",
    "reversed",
    "round",
    "set",
    "setattr",
    "slice",
    "sorted",
    "staticmethod",
    "str",
    "sum",
    "super",
    "tuple",
    "type",
    "vars",
    "zip",
};

const builtins_py310: []const []const u8 = &.{ "EncodingWarning", "aiter", "anext" };
const builtins_py311: []const []const u8 = &.{ "BaseExceptionGroup", "ExceptionGroup" };

const builtins_py313: []const []const u8 = &.{
    "PythonFinalizationError",
    "_IncompleteInputError",
};

const future_features: []const []const u8 = &.{
    "absolute_import",
    "annotations",
    "barry_as_FLUFL",
    "braces",
    "division",
    "generator_stop",
    "generators",
    "nested_scopes",
    "print_function",
    "unicode_literals",
    "with_statement",
};

const keywords: []const []const u8 = &.{
    "False",
    "None",
    "True",
    "and",
    "as",
    "assert",
    "async",
    "await",
    "break",
    "class",
    "continue",
    "def",
    "del",
    "elif",
    "else",
    "except",
    "finally",
    "for",
    "from",
    "global",
    "if",
    "import",
    "in",
    "is",
    "lambda",
    "nonlocal",
    "not",
    "or",
    "pass",
    "raise",
    "return",
    "try",
    "while",
    "with",
    "yield",
};

const magic_globals: []const []const u8 = &.{
    "__annotations__",
    "__builtins__",
    "__cached__",
    "__file__",
    "__path__",
};

const search_step_max: u32 = 33;
const soft_keywords: []const []const u8 = &.{ "_", "case", "match", "type" };

const stdlib_modules: []const []const u8 = &.{
    "__future__",
    "_abc",
    "_aix_support",
    "_ast",
    "_asyncio",
    "_bisect",
    "_blake2",
    "_bz2",
    "_codecs",
    "_codecs_cn",
    "_codecs_hk",
    "_codecs_iso2022",
    "_codecs_jp",
    "_codecs_kr",
    "_codecs_tw",
    "_collections",
    "_collections_abc",
    "_compat_pickle",
    "_compression",
    "_contextvars",
    "_crypt",
    "_csv",
    "_ctypes",
    "_curses",
    "_curses_panel",
    "_datetime",
    "_dbm",
    "_decimal",
    "_elementtree",
    "_frozen_importlib",
    "_frozen_importlib_external",
    "_functools",
    "_gdbm",
    "_hashlib",
    "_heapq",
    "_imp",
    "_io",
    "_json",
    "_locale",
    "_lsprof",
    "_lzma",
    "_markupbase",
    "_md5",
    "_msi",
    "_multibytecodec",
    "_multiprocessing",
    "_opcode",
    "_operator",
    "_osx_support",
    "_overlapped",
    "_pickle",
    "_posixshmem",
    "_posixsubprocess",
    "_py_abc",
    "_pydatetime",
    "_pydecimal",
    "_pyio",
    "_pylong",
    "_queue",
    "_random",
    "_scproxy",
    "_sha1",
    "_sha2",
    "_sha3",
    "_signal",
    "_sitebuiltins",
    "_socket",
    "_sqlite3",
    "_sre",
    "_ssl",
    "_stat",
    "_statistics",
    "_string",
    "_strptime",
    "_struct",
    "_symtable",
    "_thread",
    "_threading_local",
    "_tkinter",
    "_tokenize",
    "_tracemalloc",
    "_typing",
    "_uuid",
    "_warnings",
    "_weakref",
    "_weakrefset",
    "_winapi",
    "_zoneinfo",
    "abc",
    "aifc",
    "antigravity",
    "argparse",
    "array",
    "ast",
    "asyncio",
    "atexit",
    "audioop",
    "base64",
    "bdb",
    "binascii",
    "bisect",
    "builtins",
    "bz2",
    "cProfile",
    "calendar",
    "cgi",
    "cgitb",
    "chunk",
    "cmath",
    "cmd",
    "code",
    "codecs",
    "codeop",
    "collections",
    "colorsys",
    "compileall",
    "concurrent",
    "configparser",
    "contextlib",
    "contextvars",
    "copy",
    "copyreg",
    "crypt",
    "csv",
    "ctypes",
    "curses",
    "dataclasses",
    "datetime",
    "dbm",
    "decimal",
    "difflib",
    "dis",
    "doctest",
    "email",
    "encodings",
    "ensurepip",
    "enum",
    "errno",
    "faulthandler",
    "fcntl",
    "filecmp",
    "fileinput",
    "fnmatch",
    "fractions",
    "ftplib",
    "functools",
    "gc",
    "genericpath",
    "getopt",
    "getpass",
    "gettext",
    "glob",
    "graphlib",
    "grp",
    "gzip",
    "hashlib",
    "heapq",
    "hmac",
    "html",
    "http",
    "idlelib",
    "imaplib",
    "imghdr",
    "importlib",
    "inspect",
    "io",
    "ipaddress",
    "itertools",
    "json",
    "keyword",
    "lib2to3",
    "linecache",
    "locale",
    "logging",
    "lzma",
    "mailbox",
    "mailcap",
    "marshal",
    "math",
    "mimetypes",
    "mmap",
    "modulefinder",
    "msilib",
    "msvcrt",
    "multiprocessing",
    "netrc",
    "nis",
    "nntplib",
    "nt",
    "ntpath",
    "nturl2path",
    "numbers",
    "opcode",
    "operator",
    "optparse",
    "os",
    "ossaudiodev",
    "pathlib",
    "pdb",
    "pickle",
    "pickletools",
    "pipes",
    "pkgutil",
    "platform",
    "plistlib",
    "poplib",
    "posix",
    "posixpath",
    "pprint",
    "profile",
    "pstats",
    "pty",
    "pwd",
    "py_compile",
    "pyclbr",
    "pydoc",
    "pydoc_data",
    "pyexpat",
    "queue",
    "quopri",
    "random",
    "re",
    "readline",
    "reprlib",
    "resource",
    "rlcompleter",
    "runpy",
    "sched",
    "secrets",
    "select",
    "selectors",
    "shelve",
    "shlex",
    "shutil",
    "signal",
    "site",
    "smtplib",
    "sndhdr",
    "socket",
    "socketserver",
    "spwd",
    "sqlite3",
    "sre_compile",
    "sre_constants",
    "sre_parse",
    "ssl",
    "stat",
    "statistics",
    "string",
    "stringprep",
    "struct",
    "subprocess",
    "sunau",
    "symtable",
    "sys",
    "sysconfig",
    "syslog",
    "tabnanny",
    "tarfile",
    "telnetlib",
    "tempfile",
    "termios",
    "textwrap",
    "this",
    "threading",
    "time",
    "timeit",
    "tkinter",
    "token",
    "tokenize",
    "tomllib",
    "trace",
    "traceback",
    "tracemalloc",
    "tty",
    "turtle",
    "turtledemo",
    "types",
    "typing",
    "unicodedata",
    "unittest",
    "urllib",
    "uu",
    "uuid",
    "venv",
    "warnings",
    "wave",
    "weakref",
    "webbrowser",
    "winreg",
    "winsound",
    "wsgiref",
    "xdrlib",
    "xml",
    "xmlrpc",
    "zipapp",
    "zipfile",
    "zipimport",
    "zlib",
    "zoneinfo",
};

fn holds(table: []const []const u8, name: []const u8) bool {
    assert(table.len > 0);
    assert(table.len < std.math.maxInt(u32));
    assert(name.len <= std.math.maxInt(u32));

    var low: u32 = 0;
    var high: u32 = @intCast(table.len);

    for (0..search_step_max) |_| {
        if (low >= high) return false;

        const middle = low + @divFloor(high - low, 2);

        assert(middle < high);

        switch (std.mem.order(u8, table[middle], name)) {
            .eq => return true,
            .gt => high = middle,
            .lt => low = middle + 1,
        }
    }

    unreachable;
}

pub fn is_builtin(name: []const u8, version: PythonVersion) bool {
    if (holds(builtins, name)) return true;
    if (holds(magic_globals, name)) return true;

    const py310 = version.at_least(.py310) and holds(builtins_py310, name);
    const py311 = version.at_least(.py311) and holds(builtins_py311, name);
    const py313 = version.at_least(.py313) and holds(builtins_py313, name);

    if (py311) assert(version.at_least(.py310));
    if (py313) assert(version.at_least(.py311));

    return py310 or py311 or py313;
}

pub fn is_dunder(name: []const u8) bool {
    if (name.len <= 4) return false;

    const result = std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "__");

    if (result) assert(name[0] == '_');
    if (result) assert(name[name.len - 1] == '_');

    return result;
}

fn is_future_feature(name: []const u8) bool {
    assert(name.len > 0);

    const result = holds(future_features, name);

    if (result) assert(std.ascii.isLower(name[0]));
    if (result) assert(!is_dunder(name));

    return result;
}

fn is_keyword(name: []const u8) bool {
    assert(name.len <= std.math.maxInt(u32));

    const result = holds(keywords, name);

    if (result) assert(name.len >= 2);
    if (result) assert(!holds(soft_keywords, name));

    return result;
}

fn is_magic_global(name: []const u8) bool {
    assert(name.len <= std.math.maxInt(u32));

    const result = holds(magic_globals, name);

    if (result) assert(is_dunder(name));
    if (result) assert(!is_mangled_private(name));

    return result;
}

fn is_mangled_private(name: []const u8) bool {
    if (name.len <= 2) return false;

    const result = std.mem.startsWith(u8, name, "__") and !std.mem.endsWith(u8, name, "__");

    if (result) assert(name[0] == '_');
    if (result) assert(!is_dunder(name));

    return result;
}

fn is_soft_keyword(name: []const u8) bool {
    assert(name.len <= std.math.maxInt(u32));

    const result = holds(soft_keywords, name);

    if (result) assert(name.len <= 5);
    if (result) assert(!holds(keywords, name));

    return result;
}

pub fn is_module(name: []const u8) bool {
    assert(name.len <= std.math.maxInt(u32));

    const head = name[0 .. std.mem.findScalar(u8, name, '.') orelse name.len];
    const result = holds(stdlib_modules, head);

    assert(head.len <= name.len);
    if (result) assert(head.len > 0);

    return result;
}

test "a python version orders by its minor release" {
    try std.testing.expect(PythonVersion.py310.at_least(.py39));
    try std.testing.expect(!PythonVersion.py39.at_least(.py310));
    try std.testing.expectEqual(10, PythonVersion.py310.minor());
    try std.testing.expectEqualStrings("3.14", PythonVersion.py314.name());
}

test "every table is sorted and holds no duplicate" {
    const every_table = [_][]const []const u8{
        builtins,
        builtins_py310,
        builtins_py311,
        builtins_py313,
        future_features,
        keywords,
        magic_globals,
        soft_keywords,
        stdlib_modules,
    };

    for (every_table) |table| {
        try std.testing.expect(table.len > 0);

        for (table[0 .. table.len - 1], table[1..]) |left, right| {
            try std.testing.expect(std.mem.order(u8, left, right) == .lt);
        }
    }
}

test "a builtin arrives in the version that added it" {
    try std.testing.expect(!is_builtin("aiter", .py39));
    try std.testing.expect(is_builtin("aiter", .py310));
    try std.testing.expect(!is_builtin("ExceptionGroup", .py310));
    try std.testing.expect(is_builtin("ExceptionGroup", .py311));
    try std.testing.expect(!is_builtin("PythonFinalizationError", .py312));
    try std.testing.expect(is_builtin("PythonFinalizationError", .py313));
    try std.testing.expect(is_builtin("len", .py38));
    try std.testing.expect(is_builtin("__file__", .py38));
    try std.testing.expect(!is_builtin("missing", .py314));
}

test "a dotted module reads from its first segment" {
    try std.testing.expect(is_module("os.path"));
    try std.testing.expect(is_module("os"));
    try std.testing.expect(!is_module("requests.auth"));
}

test "a dunder and a mangled private read apart" {
    try std.testing.expect(is_dunder("__x__"));
    try std.testing.expect(!is_dunder("__x"));
    try std.testing.expect(!is_dunder("____"));
    try std.testing.expect(is_mangled_private("__x"));
    try std.testing.expect(!is_mangled_private("__x__"));
    try std.testing.expect(!is_mangled_private("_x"));
}

test "a keyword and a soft keyword read apart" {
    try std.testing.expect(is_keyword("class"));
    try std.testing.expect(!is_keyword("match"));
    try std.testing.expect(is_soft_keyword("match"));
    try std.testing.expect(is_soft_keyword("_"));
    try std.testing.expect(!is_soft_keyword("class"));
}

test "a future feature and a magic global read from their tables" {
    try std.testing.expect(is_future_feature("annotations"));
    try std.testing.expect(!is_future_feature("typing"));
    try std.testing.expect(is_magic_global("__file__"));
    try std.testing.expect(!is_magic_global("__doc__"));
}

test "a version compares on its release order" {
    try std.testing.expect(PythonVersion.py312.at_least(.py310));
    try std.testing.expect(PythonVersion.py310.at_least(.py310));
    try std.testing.expect(!PythonVersion.py39.at_least(.py310));
    try std.testing.expectEqualStrings("3.10", PythonVersion.py310.name());
    try std.testing.expectEqual(8, PythonVersion.py38.minor());
}
