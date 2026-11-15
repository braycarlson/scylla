if (ready) {
    function hoisted() {}
}

hoisted();

function outer(shadowed) {
    "use strict";

    if (ready) {
        function scoped() {}
    }

    return [shadowed, scoped];
}

function sloppy(shadowed) {
    if (ready) {
        function shadowed() {}
    }

    return shadowed;
}

if (ready) {
    function twice() {}
} else {
    function twice() {}
}

twice();

(function (window, undefined) {
    return window === undefined;
})(this);

outer();
sloppy();
