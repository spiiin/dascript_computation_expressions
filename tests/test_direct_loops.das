options gen2
require ../lib/computation.das
require ../lib/validation_builder.das

// Loops of the direct builders (Result, Option, Validation) are native: the
// body runs in the computation's own scope, so break, continue and an early
// return work, while a failed bind still leaves the whole computation.

var opened = fixed_array(0, 0, 0)
var closed = fixed_array(0, 0, 0)
var pulled = fixed_array(0, 0, 0)

struct Resource {
    id : int
}
def acquire(id : int) {
    opened[id]++
    return Resource(id = id)
}
def ce_dispose(var resource : Resource) {
    closed[resource.id]++
}
def reset() {
    for (value in opened) { value = 0 }
    for (value in closed) { value = 0 }
    for (value in pulled) { value = 0 }
}
// A source with something to release when the loop stops early.
def stream(id : int) {
    return <- computation(SequenceBuilder()) {
        let resource = acquire(id) |> use_resource
        for (i in range(5)) {
            pulled[id]++
            yield i
        }
    }
}
def step(value : int) : Result<int;string> {
    return value == 3 ? result_error("three", type<int>) : result_ok(value)
}

def test_break_and_continue() {
    var seen : array<int>
    let result = computation(ResultBuilder()) {
        for (i in range(10)) {
            if (i == 1) { continue }
            if (i == 5) { break }
            let value = result_ok(i) |> bind
            seen |> push(value)
        }
        return length(seen)
    }
    assert(result is ok && (result as ok) == 4)
    assert(seen[0] == 0 && seen[1] == 2 && seen[3] == 4)
    delete seen
}

def find_first(values : array<int>; wanted : int) {
    return computation(OptionBuilder()) {
        for (value in values) {
            if (value == wanted) {
                return value * 10
            }
        }
        return -1
    }
}
def test_early_return() {
    var inscope values <- [4, 5, 6]
    let found = find_first(values, 5)
    assert(found is some && (found as some) == 50)
    let missing = find_first(values, 7)
    assert(missing is some && (missing as some) == -1)
    // The array is not left locked by the early return.
    values |> push(7)
}

def test_failure_stops_the_loop() {
    var visited = 0
    var after = 0
    let result = computation(ResultBuilder()) {
        var sum = 0
        for (i in range(10)) {
            visited++
            let value = step(i) |> bind
            sum += value
        }
        after++
        return sum
    }
    assert(result is err && (result as err) == "three" && visited == 4 && after == 0)
    // A loop that is the last statement leaves a Unit.
    visited = 0
    let unit = computation(OptionBuilder()) {
        for (i in range(3)) {
            visited++
        }
    }
    assert(unit is some && visited == 3)
}

def test_nested_loops() {
    var cells = 0
    let returned = computation(ResultBuilder()) {
        for (row in range(3)) {
            for (column in range(3)) {
                // Leaves the inner loop only.
                if (column == 2) { break }
                // Leaves both loops and the computation.
                if (row == 2 && column == 1) {
                    return cells * 100
                }
                cells++
            }
        }
        return cells
    }
    assert(returned is ok && (returned as ok) == 500)
    var inner = 0
    var outer = 0
    let failed = computation(ResultBuilder()) {
        for (row in range(3)) {
            outer++
            for (column in range(3)) {
                inner++
                step(row + column) |> bind
            }
        }
    }
    // 0+0, 0+1, 0+2, 1+0, 1+1, 1+2 == 3 fails.
    assert(failed is err && outer == 2 && inner == 6)
}

def test_while() {
    var attempts = 0
    let result = computation(OptionBuilder()) {
        var total = 0
        while (true) {
            attempts++
            if (attempts > 100) { break }
            let value = (attempts < 5 ? some(attempts) : default<Option<int>>) |> bind
            total += value
        }
        return total
    }
    assert(result is none && attempts == 5)
    var count = 0
    let counted = computation(ResultBuilder()) {
        while (count < 10) {
            count++
            if (count % 2 == 0) { continue }
            if (count == 7) { break }
        }
        return count
    }
    assert(counted is ok && (counted as ok) == 7)
}

def test_zip_and_mutation() {
    var inscope values <- [1, 2, 3, 4]
    var slots = fixed_array(10, 20, 30, 40)
    let result = computation(ResultBuilder()) {
        for (value, slot in values, slots) {
            if (value == 3) { break }
            value += 100
            slot += value
        }
    }
    assert(result is ok)
    assert(values[0] == 101 && values[1] == 102 && values[2] == 3)
    assert(slots[0] == 111 && slots[1] == 122 && slots[2] == 30)
    values |> push(5)
}

// However a loop stops, its source is closed before the computation goes on.
def test_sources_close() {
    reset()
    var after = 0
    let broken = computation(ResultBuilder()) {
        for (value in stream(0)) {
            if (value == 2) { break }
        }
        assert(closed[0] == 1)
        after++
    }
    assert(broken is ok && opened[0] == 1 && closed[0] == 1 && pulled[0] == 3 && after == 1)
    let returned = computation(OptionBuilder()) {
        for (value in stream(1)) {
            if (value == 1) {
                return value
            }
        }
        return -1
    }
    assert(returned is some && (returned as some) == 1 && opened[1] == 1 && closed[1] == 1 && pulled[1] == 2)
    let failed = computation(ResultBuilder()) {
        for (left, right in stream(2), range(10)) {
            step(left + right * 2) |> bind
        }
    }
    // 0, 3: the second pair fails.
    assert(failed is err && opened[2] == 1 && closed[2] == 1 && pulled[2] == 2)
}

def test_scopes_inside_a_loop() {
    reset()
    let result = computation(ResultBuilder()) {
        for (i in range(3)) {
            let resource = acquire(i) |> use_resource
            step(i == 1 ? 3 : i) |> bind
        }
    }
    assert(result is err && opened[0] == 1 && closed[0] == 1 && opened[1] == 1 && closed[1] == 1 && opened[2] == 0)
    var recovered = 0
    let guarded = computation(ResultBuilder()) {
        for (i in range(3)) {
            try_with($ {
                if (i == 1) { panic("boom") }
            }, $(message : string) {
                recovered++
            })
        }
        return recovered
    }
    assert(guarded is ok && (guarded as ok) == 1)
}

// try_with, try_finally and the scope after use_resource are blocks handed to
// the builder. A break or continue inside them still reaches the loop, and
// the resource is released and the cleanup runs on the way out.
def test_leaving_from_scopes() {
    reset()
    var seen : array<int>
    let scoped = computation(ResultBuilder()) {
        for (i in range(3)) {
            let resource = acquire(i) |> use_resource
            if (i == 0) { continue }
            seen |> push(i)
            if (i == 1) { break }
        }
        return length(seen)
    }
    assert(scoped is ok && (scoped as ok) == 1 && seen[0] == 1)
    assert(opened[0] == 1 && closed[0] == 1 && opened[1] == 1 && closed[1] == 1 && opened[2] == 0)
    delete seen
    // Through two scopes: a resource inside a try_finally.
    reset()
    var cleanups = 0
    var bodies = 0
    let nested = computation(OptionBuilder()) {
        for (i in range(3)) {
            try_finally($ {
                let resource = acquire(i) |> use_resource
                if (i == 1) { break }
                bodies++
            }, $ {
                cleanups++
            })
            bodies += 10
        }
        return bodies
    }
    // i == 0 runs both parts of the body; i == 1 leaves before either.
    assert(nested is some && (nested as some) == 11 && cleanups == 2)
    assert(opened[0] == 1 && closed[0] == 1 && opened[1] == 1 && closed[1] == 1 && opened[2] == 0)
    var total = 0
    var count = 0
    let guarded = computation(ResultBuilder()) {
        while (true) {
            count++
            try_with($ {
                if (count == 2) { continue }
                if (count == 4) { break }
                total += count
            }, $(message : string) {
                total = -1
            })
        }
        return total
    }
    assert(guarded is ok && (guarded as ok) == 4 && count == 4)
    // Only the loop that holds the scope is left.
    var inner = 0
    var outer = 0
    let layered = computation(ResultBuilder()) {
        for (row in range(2)) {
            outer++
            for (column in range(5)) {
                let resource = acquire(row) |> use_resource
                if (column == 1) { break }
                inner++
            }
        }
        return inner
    }
    assert(layered is ok && (layered as ok) == 2 && outer == 2)
}

enum Fault {
    TooBig
}
def limited(value : int) : Result<int;Fault> {
    return value > 2 ? err(Fault.TooBig, type<int>) : ok(value, type<Fault>)
}
def test_other_direct_builders() {
    var visited = 0
    let typed = computation(ResultBuilder(type<Fault>)) {
        var sum = 0
        for (i in range(10)) {
            visited++
            let value = limited(i) |> bind
            sum += value
        }
        return sum
    }
    assert(typed is err && (typed as err) == Fault.TooBig && visited == 4)
    let validated = computation(ValidationBuilder()) {
        for (i in range(3)) {
            if (i == 1) {
                return i
            }
        }
        return 0
    }
    assert(validated is valid && (validated as valid) == 1)
}

[export]
def main() {
    test_break_and_continue()
    test_early_return()
    test_failure_stops_the_loop()
    test_nested_loops()
    test_while()
    test_zip_and_mutation()
    test_sources_close()
    test_scopes_inside_a_loop()
    test_leaving_from_scopes()
    test_other_direct_builders()
    print("direct loop checks OK\n")
}
