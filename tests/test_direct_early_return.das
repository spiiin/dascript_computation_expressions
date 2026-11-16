options gen2
require dastest/testing_boost public
require ../packages/computation/computation.das

// try_finally and the scope after use_resource are blocks handed to the builder.
// A `return value` inside one is still the result of the whole computation, also
// when more code follows the block: cleanup runs, the resource is released, and
// nothing after the block is executed.

var closes = 0
var cleanups = 0
var after = 0
struct Resource { id : int }
def ce_dispose(var resource : Resource) { closes++ }

def half(value : int) : Result<int;string> {
    return value % 2 == 0 ? ok(value / 2, type<string>) : err("odd {value}", type<int>)
}

// `return` inside try_finally, with code after it.
def from_finally(value : int) : Result<int;string> {
    return computation(ResultBuilder()) {
        try_finally($ {
            let h = half(value) |> bind
            if (h > 10) { return h }
        }, $ { cleanups++ })
        after++
        return -1
    }
}
// `return` after use_resource inside a branch, with code after the branch.
def from_resource(value : int) : Result<int;string> {
    return computation(ResultBuilder()) {
        if (value > 0) {
            let resource = Resource(id = value) |> use_resource
            let h = half(value) |> bind
            if (h > 10) { return h + resource.id }
        }
        after++
        return -2
    }
}
// Both nested, and a loop inside the innermost.
def nested(limit : int) : Option<int> {
    return computation(OptionBuilder()) {
        try_finally($ {
            let resource = Resource(id = 1) |> use_resource
            try_finally($ {
                for (i in range(10)) {
                    if (i == limit) { return i * 100 + resource.id }
                }
            }, $ { cleanups++ })
            after++
        }, $ { cleanups++ })
        after++
        return -3
    }
}
// In a loop of the outer scope.
def in_loop(stop : int) : Result<int;string> {
    return computation(ResultBuilder()) {
        var seen = 0
        for (i in range(5)) {
            try_finally($ {
                if (i == stop) { return i }
            }, $ { cleanups++ })
            seen++
        }
        after++
        return 100 + seen
    }
}

[export]
def main() {
    verify(from_finally(40) |> unwrap() == 20 && cleanups == 1 && after == 0)
    verify(from_finally(4) |> unwrap() == -1 && cleanups == 2 && after == 1)
    // A failure inside the block still fails the computation, after cleanup.
    let odd = from_finally(3)
    verify(odd is err && cleanups == 3 && after == 1)
    cleanups = 0; after = 0
    verify(from_resource(40) |> unwrap() == 60 && closes == 1 && after == 0)
    verify(from_resource(4) |> unwrap() == -2 && closes == 2 && after == 1)
    verify(from_resource(-1) |> unwrap() == -2 && closes == 2 && after == 2)
    verify(from_resource(3) is err && closes == 3 && after == 2)
    closes = 0; after = 0
    verify(nested(3) |> unwrap() == 301 && cleanups == 2 && closes == 1 && after == 0)
    verify(nested(99) |> unwrap() == -3 && cleanups == 4 && closes == 2 && after == 2)
    cleanups = 0; after = 0
    verify(in_loop(2) |> unwrap() == 2 && cleanups == 3 && after == 0)
    verify(in_loop(9) |> unwrap() == 105 && cleanups == 8 && after == 1)
    print("direct early return checks OK\n")
}

[test]
def test_direct_early_return() {
    main()
}
