function twice(held, held) {}

function after(held, held, last) {
    return last;
}

function before(held, held, last) {
    return held;
}

function neither(held, held, last) {}

function redeclared(held) {
    var held = 1;
}

function rewritten(held) {
    var held = 1;

    return held;
}

twice();
after();
before();
neither();
redeclared();
rewritten();
