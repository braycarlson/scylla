fn run(value: Held) {
    let Held { one, two: renamed, .. } = value;
    let (first, second) = pair;
    let [head, tail @ ..] = list;
    let &borrowed = reference;
    let ref taken = value;
    let mut held = 1;
    let Some(inner) = option else {
        return;
    };

    match value {
        Held { one: 1, .. } => {}
        Choice::One => {}
        Choice::Two(held) => {}
        Choice::Three { held } => {}
        0 => {}
        1..=2 => {}
        'a'..='z' => {}
        "text" => {}
        true => {}
        -1 => {}
        LIMIT => {}
        held @ 1 => {}
        (one, two) => {}
        [one, two] => {}
        &one => {}
        _ => {}
    }
}

fn grouped() {
    let (held) = 1;
}
