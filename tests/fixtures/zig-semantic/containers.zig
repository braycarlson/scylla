const Shade = enum {
    light,
    dark,
};

const Holder = struct {
    field: usize,
    shade: Shade,

    fn build(one: usize) Holder {
        return Holder{ .field = one, .shade = .light };
    }

    fn read(self: Holder) usize {
        return self.field + TOP;
    }
};

const Tagged = union(Shade) {
    light: usize,
    dark: usize,
};

const TOP: usize = 4;

fn top() usize {
    return TOP;
}
