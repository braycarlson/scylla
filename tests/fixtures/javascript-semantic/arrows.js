function outer() {
    const inner = () => arguments;

    return inner;
}
