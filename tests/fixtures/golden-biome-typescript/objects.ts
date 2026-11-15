const plain = { one: 1, two: 2 };
const shorthand = { one, two };
const computed = { [key]: 1 };
const quoted = { "one-two": 1, three: 2 };
const numbered = { 1: "one", 0.5: "half" };
const spread = { ...source, extra: 1 };
const methods = {
    method() {
        return 1;
    },
    get accessor() {
        return 1;
    },
    set accessor(next) {
        this.value = next;
    },
    async awaited() {},
    *generated() {},
    async *both() {},
    ["computed"]() {},
};
const nested = { outer: { inner: 1 } };
const empty = {};
const arrays = [1, [2, [3]]];
const holes = [1, , 3];
const spreadArray = [...source, 1];
