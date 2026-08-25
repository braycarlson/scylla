if (one) {
    two();
} else if (three) {
    four();
} else {
    five();
}

for (let index = 0; index < limit; index += 1) {
    body(index);
}

for (;;) {
    break;
}

for (const item of items) {
    continue;
}

for (const key in target) {
    use(key);
}

while (running) {
    step();
}

do {
    step();
} while (running);

switch (value) {
    case 1:
    case 2: {
        handle();
        break;
    }
    default:
        fallback();
}

try {
    risky();
} catch (error) {
    report(error);
} finally {
    cleanup();
}

try {
    risky();
} catch {
    report();
}

outer: for (const item of items) {
    if (item) {
        continue outer;
    }

    break outer;
}

throw new Error("bad");
debugger;
{
    scoped();
}
