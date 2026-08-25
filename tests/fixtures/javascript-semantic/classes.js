class Shape {
    area() {
        return 1;
    }
}

const held = class Named {
    other() {
        return Named;
    }
};

const outside = Named;
