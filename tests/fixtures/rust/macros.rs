macro_rules! shout {
    ($held:expr) => {
        $held
    };
    ($one:expr, $two:expr) => {{
        $one + $two
    }};
}

fn run() {
    println!("one");
    let held = vec![1, 2, 3];
    let formatted = format!("{}", held.len());

    write!(out, "{}", held.len());
    assert!(held.len() > 0);

    matches!(held.first(), Some(_));
}

struct Held {
    held: u32,
}

impl Held {
    fn run(&self) {
        todo!()
    }
}

type Made = held!();

trait Sounded {
    held!();
}

impl Sounded for Held {
    held!();
}
