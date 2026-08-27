mod analyzer;
mod binder;
mod blob;
mod descriptor;
mod format;
mod ladder;
mod minimize;
mod normalize;
mod oracle;
mod printer;
mod record;
mod signature;

use std::cell::RefCell;
use std::io::Write as _;
use std::panic::{self, AssertUnwindSafe};
use std::path::{Path, PathBuf};

use blob::blob_of;
use descriptor::{descriptor_of, tools_of, Descriptor, EVERY_LANGUAGE};
use ladder::{Level, EVERY_LEVEL};
use record::Record;
use signature::signature_of;

const USAGE: &str = concat!(
    "usage: runner --corpus <directory> [options]\n",
    "  --corpus <directory>   the corpus root to walk\n",
    "  --language <name>      a language to run, repeatable (default: every language)\n",
    "  --level <name>         the highest ladder level to climb: ",
    "verdict, tokens, census, tree, bind, format\n",
    "  --out <path>           the divergence JSONL (default: divergences.jsonl)\n",
    "  --minimize             shrink each new signature's first repro\n",
    "  --require              treat an unavailable oracle as a harness failure\n",
);

struct Arguments {
    corpus: Option<PathBuf>,
    languages: Vec<String>,
    level: Level,
    minimize: bool,
    out: PathBuf,
    require: bool,
}

struct Tally {
    agreeing: u32,
    compared: u32,
    language: String,
    panicked: u32,
    signatures: Vec<String>,
}

thread_local! {
    static PANIC: RefCell<String> = const { RefCell::new(String::new()) };
}

fn main() {
    panic::set_hook(Box::new(|held| {
        let site = held.location().map_or_else(
            || "unknown".to_owned(),
            |place| format!("{}:{}", place.file(), place.line()),
        );

        let message = held
            .payload()
            .downcast_ref::<&str>()
            .map(|held| (*held).to_owned())
            .or_else(|| held.payload().downcast_ref::<String>().cloned())
            .unwrap_or_default();

        PANIC.with(|held| *held.borrow_mut() = format!("{site}: {message}"));
    }));

    let code = run();

    std::process::exit(code);
}

fn panicked() -> String {
    PANIC.with(|held| held.borrow().clone())
}

fn run() -> i32 {
    let arguments = match parsed(std::env::args().skip(1).collect()) {
        Ok(held) => held,
        Err(error) => return fault(&error),
    };

    let Some(corpus) = arguments.corpus.clone() else {
        return fault(&format!("no --corpus was named\n\n{USAGE}"));
    };

    if !corpus.is_dir() {
        return fault(&format!("{} is not a directory", corpus.display()));
    }

    let tools = tools_of();
    let mut records = Vec::new();
    let mut tallies = Vec::new();
    let mut unavailable = Vec::new();

    for name in &arguments.languages {
        let descriptor = match descriptor_of(name, &tools) {
            Ok(held) => held,
            Err(error) => {
                unavailable.push(format!("{name}: {error}"));

                continue;
            }
        };

        let tally = sweep(&arguments, &corpus, descriptor, &mut records);

        tallies.push(tally);
    }

    if let Err(error) = written(&arguments.out, &records) {
        return fault(&error);
    }

    report(&tallies, &unavailable, &records, &arguments.out);

    if arguments.require && !unavailable.is_empty() {
        return fault("an oracle the run requires is unavailable");
    }

    0
}

fn sweep(
    arguments: &Arguments,
    corpus: &Path,
    mut descriptor: Descriptor,
    records: &mut Vec<Record>,
) -> Tally {
    let mut tally = Tally {
        agreeing: 0,
        compared: 0,
        language: descriptor.name.to_owned(),
        panicked: 0,
        signatures: Vec::new(),
    };

    for path in sources(corpus, descriptor.extensions) {
        let Ok(source) = std::fs::read(&path) else {
            continue;
        };

        let name = relative_of(corpus, &path);

        tally.compared += 1;

        let held = panic::catch_unwind(AssertUnwindSafe(|| {
            divergence_of(arguments.level, &mut descriptor, &source)
        }));

        let found = match held {
            Ok(found) => found,
            Err(_) => {
                tally.panicked += 1;

                Some(panic_divergence(descriptor.name, &panicked()))
            }
        };

        let Some(divergence) = found else {
            tally.agreeing += 1;

            continue;
        };

        let fresh = !tally.signatures.contains(&divergence.signature);

        if fresh {
            tally.signatures.push(divergence.signature.clone());
        }

        let repro = if fresh && arguments.minimize {
            let mut probe = |candidate: &[u8]| {
                let held = panic::catch_unwind(AssertUnwindSafe(|| {
                    divergence_of(arguments.level, &mut descriptor, candidate)
                }));

                match held {
                    Ok(found) => found.map(|divergence| divergence.signature),
                    Err(_) => Some(panic_divergence(descriptor.name, &panicked()).signature),
                }
            };

            minimize::minimized(&divergence.signature, &source, &mut probe)
        } else {
            source.clone()
        };

        records.push(Record {
            blob: blob_of(&source),
            language: descriptor.name.to_owned(),
            level: divergence.level,
            offset: divergence.offset,
            oracle: descriptor.oracle.identifier().to_owned(),
            path: name,
            repro,
            signature: divergence.signature,
            summary: divergence.summary,
        });
    }

    tally
}

fn divergence_of(
    ceiling: Level,
    descriptor: &mut Descriptor,
    source: &[u8],
) -> Option<ladder::Divergence> {
    let held = descriptor.analyzer.read(source);
    let theirs = descriptor.oracle.read(source)?;

    for level in EVERY_LEVEL {
        if level > ceiling {
            break;
        }

        if level == Level::Bind {
            let found = ladder::bound(descriptor.name, descriptor.analyzer.as_mut(), source);

            if found.is_some() {
                return found;
            }

            continue;
        }

        if level == Level::Format {
            let found = ladder::formatted(
                descriptor.name,
                descriptor.analyzer.as_mut(),
                descriptor.reference.as_deref_mut(),
                descriptor.regroups,
                source,
            );

            if found.is_some() {
                return found;
            }

            continue;
        }

        if level == Level::Tokens && !descriptor.oracle.reads_tokens() {
            continue;
        }

        if matches!(level, Level::Census | Level::Tree) && !descriptor.oracle.reads_nodes() {
            continue;
        }

        if level > Level::Verdict && !theirs.accepted {
            break;
        }

        let found = ladder::compare(
            level,
            descriptor.name,
            descriptor.oracle.identifier(),
            descriptor.normalizer,
            source,
            &held,
            &theirs,
        );

        if found.is_some() {
            return found;
        }
    }

    None
}

fn panic_divergence(language: &str, site: &str) -> ladder::Divergence {
    ladder::Divergence {
        level: Level::Verdict,
        offset: 0,
        signature: signature_of(&["panic", language, site]),
        summary: format!("scylla panicked: {site}"),
    }
}

fn parsed(arguments: Vec<String>) -> Result<Arguments, String> {
    let mut held = Arguments {
        corpus: None,
        languages: Vec::new(),
        level: Level::Tree,
        minimize: false,
        out: PathBuf::from("divergences.jsonl"),
        require: false,
    };

    let mut index = 0;

    while index < arguments.len() {
        let name = arguments[index].as_str();

        index += 1;

        match name {
            "--minimize" => held.minimize = true,
            "--require" => held.require = true,
            "--corpus" | "--language" | "--level" | "--out" => {
                let Some(value) = arguments.get(index) else {
                    return Err(format!("{name} names no value\n\n{USAGE}"));
                };

                index += 1;

                match name {
                    "--corpus" => held.corpus = Some(PathBuf::from(value)),
                    "--language" => held.languages.push(value.clone()),
                    "--out" => held.out = PathBuf::from(value),
                    _ => {
                        held.level = Level::of_name(value)
                            .ok_or_else(|| format!("`{value}` names no ladder level"))?;
                    }
                }
            }
            other => return Err(format!("`{other}` is not an option\n\n{USAGE}")),
        }
    }

    if held.languages.is_empty() {
        held.languages = EVERY_LANGUAGE
            .iter()
            .map(|name| (*name).to_owned())
            .collect();
    }

    Ok(held)
}

fn relative_of(corpus: &Path, path: &Path) -> String {
    path.strip_prefix(corpus)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
}

fn report(tallies: &[Tally], unavailable: &[String], records: &[Record], out: &Path) {
    let mut open: Vec<&str> = records
        .iter()
        .map(|record| record.signature.as_str())
        .collect();

    open.sort_unstable();
    open.dedup();

    println!(
        "{:<12} {:>9} {:>9} {:>7} {:>11} {:>9}",
        "language", "compared", "agreeing", "rate", "signatures", "panics"
    );

    for tally in tallies {
        let rate = if tally.compared == 0 {
            0.0
        } else {
            f64::from(tally.agreeing) * 100.0 / f64::from(tally.compared)
        };

        println!(
            "{:<12} {:>9} {:>9} {:>6.2}% {:>11} {:>9}",
            tally.language,
            tally.compared,
            tally.agreeing,
            rate,
            tally.signatures.len(),
            tally.panicked
        );
    }

    println!();
    println!("{} divergences over {} signatures", records.len(), open.len());
    println!("written to {}", out.display());

    for line in unavailable {
        println!("unavailable: {line}");
    }
}

fn sources(root: &Path, extensions: &[&str]) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut pending = vec![root.to_path_buf()];

    while let Some(directory) = pending.pop() {
        let Ok(entries) = std::fs::read_dir(&directory) else {
            continue;
        };

        for entry in entries.flatten() {
            let path = entry.path();

            if path.is_dir() {
                pending.push(path);

                continue;
            }

            let held = path.extension().and_then(|extension| extension.to_str());

            if held.is_some_and(|extension| extensions.contains(&extension)) {
                found.push(path);
            }
        }
    }

    found.sort();

    found
}

fn written(out: &Path, records: &[Record]) -> Result<(), String> {
    let mut file = std::fs::File::create(out)
        .map_err(|error| format!("{} is not writable: {error}", out.display()))?;

    for record in records {
        writeln!(file, "{}", record.line())
            .map_err(|error| format!("{} is not writable: {error}", out.display()))?;
    }

    Ok(())
}

fn fault(message: &str) -> i32 {
    eprintln!("runner: {message}");

    1
}
