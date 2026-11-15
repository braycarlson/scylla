function written(source) {
    var key;

    for (key in source) {
        count(source);
    }
}

function returned(source) {
    var key;

    for (key in source) {
        return true;
    }

    return false;
}

function destructured(rows) {
    var first;
    var second;

    for ([first, second] of rows) {
        count(rows);
    }
}

function shorthand(rows) {
    var first;

    for ({ first } of rows) {
        return rows;
    }
}

function defaulted(rows) {
    var first;

    for ([first = 1] of rows) {
        return rows;
    }
}

function wrapped(source) {
    var key;
    var other;

    for ((key) in source) {
        return true;
    }

    for ((other) in source) {
        count(source);
    }

    return false;
}

function member(target, source) {
    for (target.key in source) {
        count(target);
    }
}

function parameter(source, key) {
    for (key in source) {
        count(source);
    }
}

function count(value) {
    return value;
}

written();
returned();
destructured();
shorthand();
defaulted();
wrapped();
member();
parameter();
