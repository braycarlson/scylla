declare global {
    var Observable: ObservableCtor;

    interface ObservableCtor {
        new <T>(): object;
    }
}

export function instantiated<T>(ctor: typeof Observable<T>): typeof Observable<T> {
    return ctor;
}

export function plain(ctor: typeof Observable): typeof Observable.prototype {
    return ctor;
}

export function member<T>(ctor: typeof Observable.prototype.constructor<T>): unknown {
    return ctor;
}

const local = <T>(value: T) => value;

export type Local = typeof local<string>;
