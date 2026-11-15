function outer() {
    with (held) {
        return missing;
    }
}

function other() {
    eval("1");

    return absent;
}

function third() {
    return elsewhere;
}
