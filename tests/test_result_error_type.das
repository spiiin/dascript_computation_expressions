options gen2
require ../lib/computation.das

// ResultBuilder(type<E>) keeps the standard Result with any copyable error type.

enum LoadError {
    NotFound
    Denied
}
struct Rejection {
    code : int
    reason : string
}

var evaluated = 0

def find(id : int) : $Result<int;LoadError> {
    evaluated++
    if (id < 0) { return err(LoadError.NotFound, type<int>) }
    if (id > 100) { return err(LoadError.Denied, type<int>) }
    return ok(id, type<LoadError>)
}
def admit(age : int) : $Result<int;Rejection> {
    if (age < 18) { return err(Rejection(code=age, reason="minor"), type<int>) }
    return ok(age, type<Rejection>)
}

def load(first, second : int) {
    return computation(ResultBuilder(type<LoadError>)) {
        let a = find(first) |> bind
        if (a == 42) { return "answer" }
        let b = find(second) |> bind
        return "{a}+{b}"
    }
}
def test_sequence() {
    let both = load(1, 2)
    assert(both is ok && (both as ok) == "1+2")
    let early = load(42, -1)
    assert(early is ok && (early as ok) == "answer")
    evaluated = 0
    let missing = load(-1, 2)
    assert(missing is err && (missing as err) == LoadError.NotFound && evaluated == 1)
    let denied = load(1, 500)
    assert(denied is err && (denied as err) == LoadError.Denied)
}

def test_loops_and_groups() {
    var total = 0
    let summed = computation(ResultBuilder(type<LoadError>)) {
        for (id in [1, 2, 3]) {
            let value = find(id) |> bind
            total += value
        }
        var next = 4
        while (next < 6) {
            find(next) |> bind
            next++
        }
        for (left, right in range(2), range(10, 12)) {
            let pair = find(left) |> and_bind(find(right)) |> bind
            total += pair.first + pair.second
        }
        return total
    }
    assert(summed is ok && (summed as ok) == 6 + 10 + 12)
    total = 0
    let stopped = computation(ResultBuilder(type<LoadError>)) {
        for (id in [1, -2, 3]) {
            let value = find(id) |> bind
            total += value
        }
        return total
    }
    assert(stopped is err && (stopped as err) == LoadError.NotFound && total == 1)
    let grouped = computation(ResultBuilder(type<LoadError>)) {
        let pair = find(500) |> and_bind(find(-1)) |> bind
        return pair.first
    }
    // Both sources run; the first failure in source order wins.
    assert(grouped is err && (grouped as err) == LoadError.Denied)
}

def test_struct_error() {
    var cleaned = 0
    let admitted = computation(ResultBuilder(type<Rejection>)) {
        let age = admit(30) |> bind
        try_finally($ { admit(age + 1) |> bind }, $ { cleaned++ })
        return age
    }
    assert(admitted is ok && (admitted as ok) == 30 && cleaned == 1)
    let rejected = computation(ResultBuilder(type<Rejection>)) {
        let age = admit(12) |> bind
        return age
    }
    assert(rejected is err && (rejected as err).code == 12 && (rejected as err).reason == "minor")
    let forwarded = computation(ResultBuilder(type<Rejection>)) {
        return admit(7) |> return_from
    }
    assert(forwarded is err && (forwarded as err).code == 7)
    let unit = computation(ResultBuilder(type<Rejection>)) {
        admit(40) |> bind
    }
    assert(unit is ok)
}

[export]
def main() {
    test_sequence()
    test_loops_and_groups()
    test_struct_error()
    print("result error type checks OK\n")
}
