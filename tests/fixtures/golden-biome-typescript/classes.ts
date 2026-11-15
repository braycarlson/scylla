class Plain {
    constructor(value) {
        this.value = value;
    }

    method(one) {
        return super.method(one);
    }

    get accessor() {
        return this.value;
    }

    set accessor(next) {
        this.value = next;
    }

    static create() {
        return new Plain(1);
    }

    static field = 1;

    instance = 2;

    #private = 3;

    #hidden() {
        return this.#private;
    }

    async awaited() {}

    *generated() {}

    async *both() {}

    ["computed"]() {}

    static {
        Plain.ready = true;
    }
}

class Derived extends Plain {
    constructor() {
        super();
    }
}

const anonymous = class {};
const named = class Inner extends Plain {};

interface Readable {
    read(): void;
}

class Implementing extends Plain implements Readable {
    override ready(): void {}

    read(): this {
        return this;
    }
}
