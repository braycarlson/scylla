#[path = "generate/json.rs"]
mod json;
#[path = "generate/regex.rs"]
mod regex;

use std::collections::HashMap;
use std::path::PathBuf;

use json::Value;

const RULE_COUNT_MAX: usize = 1 << 12;
const SENTENCE_BYTES_MAX: usize = 1 << 14;

const USAGE: &str = concat!(
    "usage: generate --grammar <grammar.json> --extension <ext> --out <directory>\n",
    "  --grammar <path>       a tree-sitter grammar.json\n",
    "  --extension <ext>      the extension to write, without the dot\n",
    "  --out <directory>      where the sentences are written\n",
    "  --report               print every rule and its sentence, hidden rules included\n",
);

struct Arguments {
    extension: String,
    grammar: PathBuf,
    out: PathBuf,
    report: bool,
}

fn main() {
    let code = match run() {
        Ok(count) => {
            println!("wrote {count} sentences");

            0
        }
        Err(error) => {
            eprintln!("generate: {error}");

            1
        }
    };

    std::process::exit(code);
}

fn run() -> Result<usize, String> {
    let arguments = parsed(std::env::args().skip(1).collect())?;

    let text = std::fs::read_to_string(&arguments.grammar)
        .map_err(|error| format!("{} is unreadable: {error}", arguments.grammar.display()))?;

    let grammar = json::parse(&text)?;

    let Some(Value::Object(rules)) = grammar.get("rules") else {
        return Err("the grammar carries no `rules` object".to_owned());
    };

    if rules.len() > RULE_COUNT_MAX {
        return Err(format!("the grammar carries more than {RULE_COUNT_MAX} rules"));
    }

    let shortest = resolved(rules);

    if arguments.report {
        let mut held: Vec<&String> = rules.keys().collect();

        held.sort();

        for name in held {
            let sentence = shortest
                .get(name.as_str())
                .map_or("<unresolved>", String::as_str);

            println!("{name}\t{sentence}");
        }
    }

    std::fs::create_dir_all(&arguments.out)
        .map_err(|error| format!("{} is not writable: {error}", arguments.out.display()))?;

    let mut names: Vec<&String> = rules.keys().collect();

    names.sort();

    let mut count = 0;

    for name in names {
        if name.starts_with('_') {
            continue;
        }

        let Some(sentence) = shortest.get(name.as_str()) else {
            continue;
        };

        let held = sentence.trim();

        if held.is_empty() || held.len() > SENTENCE_BYTES_MAX {
            continue;
        }

        let path = arguments
            .out
            .join(format!("{name}.{}", arguments.extension));

        std::fs::write(&path, format!("{held}\n"))
            .map_err(|error| format!("{} is not writable: {error}", path.display()))?;

        count += 1;
    }

    Ok(count)
}

fn resolved(rules: &HashMap<String, Value>) -> HashMap<String, String> {
    let mut found: HashMap<String, String> = HashMap::new();
    let mut names: Vec<&String> = rules.keys().collect();

    names.sort();

    for _ in 0..rules.len() + 1 {
        let mut moved = false;

        for name in &names {
            let rule = &rules[*name];

            let Some(held) = sentence_of(rule, &found) else {
                continue;
            };

            let shorter = found
                .get(name.as_str())
                .is_none_or(|carried| weight_of(&held) < weight_of(carried));

            if !shorter {
                continue;
            }

            found.insert((*name).clone(), held);
            moved = true;
        }

        if !moved {
            break;
        }
    }

    found
}

fn weight_of(held: &str) -> (usize, u8, String) {
    let wordless = !held
        .chars()
        .any(|byte| byte.is_alphanumeric() || byte == '_');

    (held.len(), u8::from(wordless), held.to_owned())
}

fn sentence_of(rule: &Value, found: &HashMap<String, String>) -> Option<String> {
    let kind = rule.get("type")?.text()?;

    match kind {
        "BLANK" | "REPEAT" => Some(String::new()),
        "STRING" => Some(rule.get("value")?.text()?.to_owned()),
        "PATTERN" => Some(regex::sample_of(rule.get("value")?.text()?)),
        "SYMBOL" => found.get(rule.get("name")?.text()?).cloned(),
        "ALIAS" | "FIELD" | "IMMEDIATE_TOKEN" | "PREC" | "PREC_DYNAMIC" | "PREC_LEFT"
        | "PREC_RIGHT" | "REPEAT1" | "TOKEN" => {
            let held = rule.get("content").or_else(|| rule.get("value"))?;

            sentence_of(held, found)
        }
        "SEQ" => {
            let Value::Array(members) = rule.get("members")? else {
                return None;
            };

            let mut held = String::new();

            for member in members {
                let part = sentence_of(member, found)?;

                if part.is_empty() {
                    continue;
                }

                if !held.is_empty() {
                    held.push(' ');
                }

                held.push_str(&part);
            }

            Some(held)
        }
        "CHOICE" => {
            let Value::Array(members) = rule.get("members")? else {
                return None;
            };

            members
                .iter()
                .filter_map(|member| sentence_of(member, found))
                .min_by_key(|held| weight_of(held))
        }
        _ => None,
    }
}

fn parsed(arguments: Vec<String>) -> Result<Arguments, String> {
    let mut extension = None;
    let mut grammar = None;
    let mut out = None;
    let mut report = false;
    let mut index = 0;

    while index < arguments.len() {
        let name = arguments[index].as_str();

        index += 1;

        if name == "--report" {
            report = true;

            continue;
        }

        let Some(value) = arguments.get(index) else {
            return Err(format!("{name} names no value\n\n{USAGE}"));
        };

        index += 1;

        match name {
            "--extension" => extension = Some(value.clone()),
            "--grammar" => grammar = Some(PathBuf::from(value)),
            "--out" => out = Some(PathBuf::from(value)),
            other => return Err(format!("`{other}` is not an option\n\n{USAGE}")),
        }
    }

    Ok(Arguments {
        extension: extension.ok_or_else(|| format!("no --extension was named\n\n{USAGE}"))?,
        grammar: grammar.ok_or_else(|| format!("no --grammar was named\n\n{USAGE}"))?,
        out: out.ok_or_else(|| format!("no --out was named\n\n{USAGE}"))?,
        report,
    })
}
