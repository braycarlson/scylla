declare global {
    namespace JSX {
        interface Element {
            unknownProperty: string;
        }
    }
}

declare module "virtual" {
    namespace outer.inner {
        interface Nested {
            field: string;
        }
    }

    namespace plain {
        interface Hidden {
            field: number;
        }

        type Alias = Hidden;
    }
}

namespace local {
    interface Dropped {
        field: string;
    }
}

export {};
