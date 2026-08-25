call();

function call() {
    return named;
}

const held = function named() {
    return named;
};

const unnamed = function () {
    return held;
};
