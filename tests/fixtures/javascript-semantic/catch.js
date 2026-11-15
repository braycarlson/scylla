function outer() {
    try {
        return 1;
    } catch (held) {
        var climbed = held;
    }

    return climbed;
}
