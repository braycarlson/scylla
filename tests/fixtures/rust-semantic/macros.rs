macro_rules! shout {
    () => {
        1
    };
}

fn run() -> usize {
    shout!()
}

fn early() -> usize {
    whisper!()
}

macro_rules! whisper {
    () => {
        0
    };
}
