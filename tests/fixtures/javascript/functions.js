function plain(one, two) {
    return one + two;
}

function defaulted(one = 1, { two } = {}, ...rest) {
    return rest;
}

async function waited() {
    await ready();
}

function* generated() {
    yield one;
    yield* other();
    yield;
}

async function* both() {
    for await (const item of stream) {
        yield item;
    }
}

const arrow = (one, two) => one + two;
const single = one => one;
const blocked = () => { return 1; };
const objected = () => ({ key: 1 });
const waiting = async (one) => await one;
const shorthand = async one => one;
const expression = function named(one) { return one; };
const anonymous = function () {};
const star = function* () {};
