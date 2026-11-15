if (ready) {
    function scoped(): void {}
}

scoped();

function wrapped(undefined: number): number {
    return undefined;
}

wrapped(1);
