function outer() {
    var held = 1;

    {
        var held = 2;

        var inner = held;
    }

    return inner;
}
