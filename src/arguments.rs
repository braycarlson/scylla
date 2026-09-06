use std::env::args_os;
use std::ffi::OsString;
use std::fs::read_to_string;
use std::io::{Write as _, stderr};
use std::process::exit;

pub const ARGFILE_DEPTH_MAX: usize = 8;
pub const ARGFILE_PREFIX: char = '@';
pub const EXIT_USAGE: i32 = 2;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Word {
    Option {
        inline: Option<String>,
        name: String,
    },
    Positional(String),
}

#[derive(Debug)]
pub struct Arguments {
    index: usize,
    literal: bool,
    words: Vec<String>,
}

impl Arguments {
    pub fn of(given: &[OsString]) -> Result<Self, String> {
        assert!(!crate::allocation::is_frozen());

        let widened = expanded(given);
        let mut words: Vec<String> = Vec::with_capacity(widened.len());

        for argument in widened {
            let Some(text) = argument.to_str() else {
                return Err("an argument is not valid UTF-8".to_owned());
            };

            words.push(text.to_owned());
        }

        Ok(Self {
            index: 0,
            literal: false,
            words,
        })
    }

    pub fn from_environment() -> Result<Self, String> {
        let given: Vec<OsString> = args_os().skip(1).collect();

        Self::of(&given)
    }

    pub fn count(&self) -> usize {
        self.words.len()
    }

    pub fn next(&mut self) -> Option<Word> {
        let mut word = self.words.get(self.index)?.clone();

        self.index += 1;

        if word == "--" && !self.literal {
            self.literal = true;
            word.clone_from(self.words.get(self.index)?);
            self.index += 1;
        }

        if self.literal || !word.starts_with('-') || word == "-" {
            return Some(Word::Positional(word));
        }

        let (name, inline) = word
            .split_once('=')
            .map_or((word.as_str(), None), |(name, value)| (name, Some(value)));

        Some(Word::Option {
            inline: inline.map(str::to_owned),
            name: name.to_owned(),
        })
    }

    pub fn value(&mut self, name: &str, inline: Option<String>) -> Result<String, String> {
        if let Some(held) = inline {
            return Ok(held);
        }

        let Some(next) = self.words.get(self.index) else {
            return Err(format!(
                "a value is required for '{name}' but none was supplied"
            ));
        };

        self.index += 1;

        Ok(next.clone())
    }
}

pub fn expanded(arguments: &[OsString]) -> Vec<OsString> {
    assert!(!crate::allocation::is_frozen());

    let mut pending: Vec<OsString> = arguments.to_vec();

    for _ in 0..ARGFILE_DEPTH_MAX {
        let mut widened: Vec<OsString> = Vec::with_capacity(pending.len());
        let mut expanded_any = false;

        for argument in pending {
            let Some(read) = read_argfile(&argument) else {
                widened.push(argument);

                continue;
            };

            expanded_any = true;

            widened.extend(read);
        }

        pending = widened;

        if !expanded_any {
            return pending;
        }
    }

    pending
}

pub fn split_into(target: &mut Vec<String>, value: &str) {
    assert!(!crate::allocation::is_frozen());

    for item in value.split(',') {
        let trimmed = item.trim();

        if !trimmed.is_empty() {
            target.push(trimmed.to_owned());
        }
    }
}

#[expect(
    clippy::exit,
    reason = "a usage error ends the process before the run starts, the way every command line \
              tool does"
)]
pub fn usage_exit(usage: &str, message: &str) -> ! {
    let mut err = stderr().lock();
    let _written = err.write_all(b"error: ");
    let _message = err.write_all(message.as_bytes());
    let _gap = err.write_all(b"\n\n");
    let _usage = err.write_all(usage.as_bytes());

    exit(EXIT_USAGE)
}

fn is_argfile(argument: &OsString) -> bool {
    let Some(text) = argument.to_str() else {
        return false;
    };

    text.len() > 1 && text.starts_with(ARGFILE_PREFIX)
}

fn read_argfile(argument: &OsString) -> Option<Vec<OsString>> {
    if !is_argfile(argument) {
        return None;
    }

    let text = argument.to_str().unwrap_or_default();
    let path = text.get(ARGFILE_PREFIX.len_utf8()..).unwrap_or_default();

    let Ok(body) = read_to_string(path) else {
        return None;
    };

    Some(
        body.lines()
            .map(str::trim_end)
            .filter(|line| !line.is_empty())
            .map(OsString::from)
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arguments(words: &[&str]) -> Arguments {
        let given: Vec<OsString> = words.iter().map(OsString::from).collect();

        Arguments::of(&given).expect("the arguments read")
    }

    fn option(name: &str, inline: Option<&str>) -> Word {
        Word::Option {
            inline: inline.map(str::to_owned),
            name: name.to_owned(),
        }
    }

    fn positional(text: &str) -> Word {
        Word::Positional(text.to_owned())
    }

    #[test]
    fn a_command_line_yields_its_words_in_order() {
        let mut held = arguments(&["check", "--fix", "--select", "GL,HS", "--format=json", "a"]);

        assert_eq!(held.count(), 6);
        assert_eq!(held.next(), Some(positional("check")));
        assert_eq!(held.next(), Some(option("--fix", None)));
        assert_eq!(held.next(), Some(option("--select", None)));
        assert_eq!(held.value("--select", None), Ok("GL,HS".to_owned()));
        assert_eq!(held.next(), Some(option("--format", Some("json"))));

        assert_eq!(
            held.value("--format", Some("json".to_owned())),
            Ok("json".to_owned())
        );

        assert_eq!(held.next(), Some(positional("a")));
        assert_eq!(held.next(), None);
    }

    #[test]
    fn a_dash_is_a_positional_and_a_double_dash_ends_the_options() {
        let mut held = arguments(&["-", "--", "--not-a-flag", "-x"]);

        assert_eq!(held.next(), Some(positional("-")));
        assert_eq!(held.next(), Some(positional("--not-a-flag")));
        assert_eq!(held.next(), Some(positional("-x")));
        assert_eq!(held.next(), None);
    }

    #[test]
    fn a_value_at_the_end_of_the_line_is_refused() {
        let mut held = arguments(&["--select"]);

        assert_eq!(held.next(), Some(option("--select", None)));
        assert!(held.value("--select", None).expect_err("no value").contains("--select"));
    }

    #[test]
    fn a_short_option_is_an_option() {
        let mut held = arguments(&["-q", "-o=out.txt"]);

        assert_eq!(held.next(), Some(option("-q", None)));
        assert_eq!(held.next(), Some(option("-o", Some("out.txt"))));
    }

    #[test]
    fn a_list_value_splits_on_commas_and_drops_blanks() {
        let mut target = Vec::new();

        split_into(&mut target, " GL, HS,,AL ");

        assert_eq!(target, ["GL", "HS", "AL"]);
    }

    #[test]
    fn an_argfile_expands_one_argument_per_line() {
        let directory = std::env::temp_dir().join(format!("scylla-argfile-{}", std::process::id()));

        std::fs::create_dir_all(&directory).expect("the directory is created");

        let file = directory.join("args");

        std::fs::write(&file, "check\n--fix\n\n.\n").expect("the argfile is written");

        let argument = OsString::from(format!("@{}", file.display()));
        let words = expanded(core::slice::from_ref(&argument));

        assert_eq!(words, ["check", "--fix", "."].map(OsString::from));

        let mut held = Arguments::of(&[argument]).expect("the arguments read");

        assert_eq!(held.next(), Some(positional("check")));
        assert_eq!(held.next(), Some(option("--fix", None)));

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn an_unreadable_argfile_stays_verbatim() {
        let words = expanded(&[OsString::from("@/nonexistent/scylla-args")]);

        assert_eq!(words, [OsString::from("@/nonexistent/scylla-args")]);
    }

    #[test]
    fn a_bare_at_sign_is_not_an_argfile() {
        assert_eq!(expanded(&[OsString::from("@")]), [OsString::from("@")]);
    }

    #[cfg(unix)]
    #[test]
    fn an_argument_that_is_not_text_is_refused() {
        use std::os::unix::ffi::OsStringExt as _;

        let given = [OsString::from_vec(vec![0xff, 0xfe])];

        assert!(Arguments::of(&given).is_err());
    }
}
