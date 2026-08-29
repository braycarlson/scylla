#[expect(
    clippy::arbitrary_source_item_ordering,
    reason = "the declared order is the release order that `at_least` compares on"
)]
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum PythonVersion {
    Py38,
    Py39,
    Py310,
    Py311,
    Py312,
    Py313,
    Py314,
}

impl PythonVersion {
    pub const fn at_least(self, other: Self) -> bool {
        self.minor() >= other.minor()
    }

    pub const fn minor(self) -> u8 {
        match self {
            Self::Py38 => 8,
            Self::Py39 => 9,
            Self::Py310 => 10,
            Self::Py311 => 11,
            Self::Py312 => 12,
            Self::Py313 => 13,
            Self::Py314 => 14,
        }
    }

    pub const fn name(self) -> &'static str {
        match self {
            Self::Py38 => "3.8",
            Self::Py39 => "3.9",
            Self::Py310 => "3.10",
            Self::Py311 => "3.11",
            Self::Py312 => "3.12",
            Self::Py313 => "3.13",
            Self::Py314 => "3.14",
        }
    }
}

pub const BUILTINS: &[&[u8]] = &[
    b"ArithmeticError",
    b"AssertionError",
    b"AttributeError",
    b"BaseException",
    b"BlockingIOError",
    b"BrokenPipeError",
    b"BufferError",
    b"BytesWarning",
    b"ChildProcessError",
    b"ConnectionAbortedError",
    b"ConnectionError",
    b"ConnectionRefusedError",
    b"ConnectionResetError",
    b"DeprecationWarning",
    b"EOFError",
    b"Ellipsis",
    b"EnvironmentError",
    b"Exception",
    b"False",
    b"FileExistsError",
    b"FileNotFoundError",
    b"FloatingPointError",
    b"FutureWarning",
    b"GeneratorExit",
    b"IOError",
    b"ImportError",
    b"ImportWarning",
    b"IndentationError",
    b"IndexError",
    b"InterruptedError",
    b"IsADirectoryError",
    b"KeyError",
    b"KeyboardInterrupt",
    b"LookupError",
    b"MemoryError",
    b"ModuleNotFoundError",
    b"NameError",
    b"None",
    b"NotADirectoryError",
    b"NotImplemented",
    b"NotImplementedError",
    b"OSError",
    b"OverflowError",
    b"PendingDeprecationWarning",
    b"PermissionError",
    b"ProcessLookupError",
    b"RecursionError",
    b"ReferenceError",
    b"ResourceWarning",
    b"RuntimeError",
    b"RuntimeWarning",
    b"StopAsyncIteration",
    b"StopIteration",
    b"SyntaxError",
    b"SyntaxWarning",
    b"SystemError",
    b"SystemExit",
    b"TabError",
    b"TimeoutError",
    b"True",
    b"TypeError",
    b"UnboundLocalError",
    b"UnicodeDecodeError",
    b"UnicodeEncodeError",
    b"UnicodeError",
    b"UnicodeTranslateError",
    b"UnicodeWarning",
    b"UserWarning",
    b"ValueError",
    b"Warning",
    b"ZeroDivisionError",
    b"__build_class__",
    b"__debug__",
    b"__doc__",
    b"__import__",
    b"__loader__",
    b"__name__",
    b"__package__",
    b"__spec__",
    b"abs",
    b"all",
    b"any",
    b"ascii",
    b"bin",
    b"bool",
    b"breakpoint",
    b"bytearray",
    b"bytes",
    b"callable",
    b"chr",
    b"classmethod",
    b"compile",
    b"complex",
    b"copyright",
    b"credits",
    b"delattr",
    b"dict",
    b"dir",
    b"divmod",
    b"enumerate",
    b"eval",
    b"exec",
    b"exit",
    b"filter",
    b"float",
    b"format",
    b"frozenset",
    b"getattr",
    b"globals",
    b"hasattr",
    b"hash",
    b"help",
    b"hex",
    b"id",
    b"input",
    b"int",
    b"isinstance",
    b"issubclass",
    b"iter",
    b"len",
    b"license",
    b"list",
    b"locals",
    b"map",
    b"max",
    b"memoryview",
    b"min",
    b"next",
    b"object",
    b"oct",
    b"open",
    b"ord",
    b"pow",
    b"print",
    b"property",
    b"quit",
    b"range",
    b"repr",
    b"reversed",
    b"round",
    b"set",
    b"setattr",
    b"slice",
    b"sorted",
    b"staticmethod",
    b"str",
    b"sum",
    b"super",
    b"tuple",
    b"type",
    b"vars",
    b"zip",
];

pub const BUILTINS_PY310: &[&[u8]] = &[b"EncodingWarning", b"aiter", b"anext"];
pub const BUILTINS_PY311: &[&[u8]] = &[b"BaseExceptionGroup", b"ExceptionGroup"];
pub const BUILTINS_PY313: &[&[u8]] = &[b"PythonFinalizationError", b"_IncompleteInputError"];

pub const FUTURE_FEATURES: &[&[u8]] = &[
    b"absolute_import",
    b"annotations",
    b"barry_as_FLUFL",
    b"braces",
    b"division",
    b"generator_stop",
    b"generators",
    b"nested_scopes",
    b"print_function",
    b"unicode_literals",
    b"with_statement",
];

pub const KEYWORDS: &[&[u8]] = &[
    b"False",
    b"None",
    b"True",
    b"and",
    b"as",
    b"assert",
    b"async",
    b"await",
    b"break",
    b"class",
    b"continue",
    b"def",
    b"del",
    b"elif",
    b"else",
    b"except",
    b"finally",
    b"for",
    b"from",
    b"global",
    b"if",
    b"import",
    b"in",
    b"is",
    b"lambda",
    b"nonlocal",
    b"not",
    b"or",
    b"pass",
    b"raise",
    b"return",
    b"try",
    b"while",
    b"with",
    b"yield",
];

pub const MAGIC_GLOBALS: &[&[u8]] = &[
    b"__annotations__",
    b"__builtins__",
    b"__cached__",
    b"__file__",
    b"__path__",
];

pub const SOFT_KEYWORDS: &[&[u8]] = &[b"_", b"case", b"match", b"type"];

pub const STDLIB_MODULES: &[&[u8]] = &[
    b"__future__",
    b"_abc",
    b"_aix_support",
    b"_ast",
    b"_asyncio",
    b"_bisect",
    b"_blake2",
    b"_bz2",
    b"_codecs",
    b"_codecs_cn",
    b"_codecs_hk",
    b"_codecs_iso2022",
    b"_codecs_jp",
    b"_codecs_kr",
    b"_codecs_tw",
    b"_collections",
    b"_collections_abc",
    b"_compat_pickle",
    b"_compression",
    b"_contextvars",
    b"_crypt",
    b"_csv",
    b"_ctypes",
    b"_curses",
    b"_curses_panel",
    b"_datetime",
    b"_dbm",
    b"_decimal",
    b"_elementtree",
    b"_frozen_importlib",
    b"_frozen_importlib_external",
    b"_functools",
    b"_gdbm",
    b"_hashlib",
    b"_heapq",
    b"_imp",
    b"_io",
    b"_json",
    b"_locale",
    b"_lsprof",
    b"_lzma",
    b"_markupbase",
    b"_md5",
    b"_msi",
    b"_multibytecodec",
    b"_multiprocessing",
    b"_opcode",
    b"_operator",
    b"_osx_support",
    b"_overlapped",
    b"_pickle",
    b"_posixshmem",
    b"_posixsubprocess",
    b"_py_abc",
    b"_pydatetime",
    b"_pydecimal",
    b"_pyio",
    b"_pylong",
    b"_queue",
    b"_random",
    b"_scproxy",
    b"_sha1",
    b"_sha2",
    b"_sha3",
    b"_signal",
    b"_sitebuiltins",
    b"_socket",
    b"_sqlite3",
    b"_sre",
    b"_ssl",
    b"_stat",
    b"_statistics",
    b"_string",
    b"_strptime",
    b"_struct",
    b"_symtable",
    b"_thread",
    b"_threading_local",
    b"_tkinter",
    b"_tokenize",
    b"_tracemalloc",
    b"_typing",
    b"_uuid",
    b"_warnings",
    b"_weakref",
    b"_weakrefset",
    b"_winapi",
    b"_zoneinfo",
    b"abc",
    b"aifc",
    b"antigravity",
    b"argparse",
    b"array",
    b"ast",
    b"asyncio",
    b"atexit",
    b"audioop",
    b"base64",
    b"bdb",
    b"binascii",
    b"bisect",
    b"builtins",
    b"bz2",
    b"cProfile",
    b"calendar",
    b"cgi",
    b"cgitb",
    b"chunk",
    b"cmath",
    b"cmd",
    b"code",
    b"codecs",
    b"codeop",
    b"collections",
    b"colorsys",
    b"compileall",
    b"concurrent",
    b"configparser",
    b"contextlib",
    b"contextvars",
    b"copy",
    b"copyreg",
    b"crypt",
    b"csv",
    b"ctypes",
    b"curses",
    b"dataclasses",
    b"datetime",
    b"dbm",
    b"decimal",
    b"difflib",
    b"dis",
    b"doctest",
    b"email",
    b"encodings",
    b"ensurepip",
    b"enum",
    b"errno",
    b"faulthandler",
    b"fcntl",
    b"filecmp",
    b"fileinput",
    b"fnmatch",
    b"fractions",
    b"ftplib",
    b"functools",
    b"gc",
    b"genericpath",
    b"getopt",
    b"getpass",
    b"gettext",
    b"glob",
    b"graphlib",
    b"grp",
    b"gzip",
    b"hashlib",
    b"heapq",
    b"hmac",
    b"html",
    b"http",
    b"idlelib",
    b"imaplib",
    b"imghdr",
    b"importlib",
    b"inspect",
    b"io",
    b"ipaddress",
    b"itertools",
    b"json",
    b"keyword",
    b"lib2to3",
    b"linecache",
    b"locale",
    b"logging",
    b"lzma",
    b"mailbox",
    b"mailcap",
    b"marshal",
    b"math",
    b"mimetypes",
    b"mmap",
    b"modulefinder",
    b"msilib",
    b"msvcrt",
    b"multiprocessing",
    b"netrc",
    b"nis",
    b"nntplib",
    b"nt",
    b"ntpath",
    b"nturl2path",
    b"numbers",
    b"opcode",
    b"operator",
    b"optparse",
    b"os",
    b"ossaudiodev",
    b"pathlib",
    b"pdb",
    b"pickle",
    b"pickletools",
    b"pipes",
    b"pkgutil",
    b"platform",
    b"plistlib",
    b"poplib",
    b"posix",
    b"posixpath",
    b"pprint",
    b"profile",
    b"pstats",
    b"pty",
    b"pwd",
    b"py_compile",
    b"pyclbr",
    b"pydoc",
    b"pydoc_data",
    b"pyexpat",
    b"queue",
    b"quopri",
    b"random",
    b"re",
    b"readline",
    b"reprlib",
    b"resource",
    b"rlcompleter",
    b"runpy",
    b"sched",
    b"secrets",
    b"select",
    b"selectors",
    b"shelve",
    b"shlex",
    b"shutil",
    b"signal",
    b"site",
    b"smtplib",
    b"sndhdr",
    b"socket",
    b"socketserver",
    b"spwd",
    b"sqlite3",
    b"sre_compile",
    b"sre_constants",
    b"sre_parse",
    b"ssl",
    b"stat",
    b"statistics",
    b"string",
    b"stringprep",
    b"struct",
    b"subprocess",
    b"sunau",
    b"symtable",
    b"sys",
    b"sysconfig",
    b"syslog",
    b"tabnanny",
    b"tarfile",
    b"telnetlib",
    b"tempfile",
    b"termios",
    b"textwrap",
    b"this",
    b"threading",
    b"time",
    b"timeit",
    b"tkinter",
    b"token",
    b"tokenize",
    b"tomllib",
    b"trace",
    b"traceback",
    b"tracemalloc",
    b"tty",
    b"turtle",
    b"turtledemo",
    b"types",
    b"typing",
    b"unicodedata",
    b"unittest",
    b"urllib",
    b"uu",
    b"uuid",
    b"venv",
    b"warnings",
    b"wave",
    b"weakref",
    b"webbrowser",
    b"winreg",
    b"winsound",
    b"wsgiref",
    b"xdrlib",
    b"xml",
    b"xmlrpc",
    b"zipapp",
    b"zipfile",
    b"zipimport",
    b"zlib",
    b"zoneinfo",
];

fn holds(table: &[&[u8]], name: &[u8]) -> bool {
    table.binary_search(&name).is_ok()
}

pub fn is_builtin(name: &[u8], version: PythonVersion) -> bool {
    if holds(BUILTINS, name) {
        return true;
    }

    if holds(MAGIC_GLOBALS, name) {
        return true;
    }

    if version.at_least(PythonVersion::Py310) && holds(BUILTINS_PY310, name) {
        return true;
    }

    if version.at_least(PythonVersion::Py311) && holds(BUILTINS_PY311, name) {
        return true;
    }

    version.at_least(PythonVersion::Py313) && holds(BUILTINS_PY313, name)
}

pub fn is_dunder(name: &[u8]) -> bool {
    if name.len() <= 4 {
        return false;
    }

    name.starts_with(b"__") && name.ends_with(b"__")
}

pub fn is_future_feature(name: &[u8]) -> bool {
    holds(FUTURE_FEATURES, name)
}

pub fn is_keyword(name: &[u8]) -> bool {
    holds(KEYWORDS, name)
}

pub fn is_magic_global(name: &[u8]) -> bool {
    holds(MAGIC_GLOBALS, name)
}

pub fn is_mangled_private(name: &[u8]) -> bool {
    if name.len() <= 2 {
        return false;
    }

    name.starts_with(b"__") && !name.ends_with(b"__")
}

pub fn is_soft_keyword(name: &[u8]) -> bool {
    holds(SOFT_KEYWORDS, name)
}

pub fn is_stdlib_module(name: &[u8]) -> bool {
    let head = match name.iter().position(|byte| *byte == b'.') {
        None => name,
        Some(dot) => &name[..dot],
    };

    holds(STDLIB_MODULES, head)
}

#[cfg(test)]
mod tests {
    use super::*;

    const EVERY_TABLE: [&[&[u8]]; 9] = [
        BUILTINS,
        BUILTINS_PY310,
        BUILTINS_PY311,
        BUILTINS_PY313,
        FUTURE_FEATURES,
        KEYWORDS,
        MAGIC_GLOBALS,
        SOFT_KEYWORDS,
        STDLIB_MODULES,
    ];

    #[test]
    fn every_table_is_sorted_and_holds_no_duplicate() {
        for table in EVERY_TABLE {
            assert!(!table.is_empty());

            for (left, right) in table.iter().zip(table.iter().skip(1)) {
                assert!(left < right, "the table is out of order or repeats");
            }
        }
    }

    #[test]
    fn a_builtin_arrives_in_the_version_that_added_it() {
        assert!(!is_builtin(b"aiter", PythonVersion::Py39));
        assert!(is_builtin(b"aiter", PythonVersion::Py310));
        assert!(!is_builtin(b"ExceptionGroup", PythonVersion::Py310));
        assert!(is_builtin(b"ExceptionGroup", PythonVersion::Py311));

        assert!(!is_builtin(
            b"PythonFinalizationError",
            PythonVersion::Py312
        ));

        assert!(is_builtin(b"PythonFinalizationError", PythonVersion::Py313));
        assert!(is_builtin(b"len", PythonVersion::Py38));
        assert!(is_builtin(b"__file__", PythonVersion::Py38));
        assert!(!is_builtin(b"missing", PythonVersion::Py314));
    }

    #[test]
    fn a_dotted_module_reads_from_its_first_segment() {
        assert!(is_stdlib_module(b"os.path"));
        assert!(is_stdlib_module(b"os"));
        assert!(!is_stdlib_module(b"requests.auth"));
    }

    #[test]
    fn a_dunder_and_a_mangled_private_read_apart() {
        assert!(is_dunder(b"__x__"));
        assert!(!is_dunder(b"__x"));
        assert!(!is_dunder(b"____"));
        assert!(is_mangled_private(b"__x"));
        assert!(!is_mangled_private(b"__x__"));
        assert!(!is_mangled_private(b"_x"));
    }

    #[test]
    fn a_keyword_and_a_soft_keyword_read_apart() {
        assert!(is_keyword(b"class"));
        assert!(!is_keyword(b"match"));
        assert!(is_soft_keyword(b"match"));
        assert!(is_soft_keyword(b"_"));
        assert!(!is_soft_keyword(b"class"));
    }

    #[test]
    fn a_future_feature_and_a_magic_global_read_from_their_tables() {
        assert!(is_future_feature(b"annotations"));
        assert!(!is_future_feature(b"typing"));
        assert!(is_magic_global(b"__file__"));
        assert!(!is_magic_global(b"__doc__"));
    }

    #[test]
    fn a_version_compares_on_its_release_order() {
        assert!(PythonVersion::Py312.at_least(PythonVersion::Py310));
        assert!(PythonVersion::Py310.at_least(PythonVersion::Py310));
        assert!(!PythonVersion::Py39.at_least(PythonVersion::Py310));
        assert_eq!(PythonVersion::Py310.name(), "3.10");
        assert_eq!(PythonVersion::Py38.minor(), 8);
    }
}
