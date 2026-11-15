options gen2
require ../lib/computation.das
require ../lib/validation_builder.das

// Result, Option and Validation only short-circuit, so their scopes are lowered
// without continuations: a branch may return early, and a long chain of binds
// neither nests calls nor clones the rest of the scope.

var evaluated = 0
var events = ""

struct Door { id : int }
struct Token { value : int }

def step(value : int) : Result<int;string> {
    evaluated++
    if (value < 0) { return result_error("negative {value}", type<int>) }
    return result_ok(value)
}
def maybe(value : int) : Option<int> {
    evaluated++
    if (value < 0) { return none(type<int>) }
    return some(value)
}
def checked(value : int) {
    evaluated++
    if (value < 0) { return validation_error("negative {value}", type<int>) }
    return validation_ok(value)
}
def open(id : int) {
    events += "open{id};"
    return Door(id=id)
}
def ce_dispose(var door : Door) { events += "close{door.id};" }
def ce_source(builder : ResultBuilder; token : Token) {
    events += "hook{token.value};"
    return step(token.value)
}

def classify(value : int) {
    return computation(ResultBuilder()) {
        let first = step(value) |> bind
        if (first > 100) { return "big" }
        if (first == 7) {
            let inner = step(first - 10) |> bind
            return "seven {inner}"
        } elif (first == 8) {
            return "eight"
        } else {
            events += "other;"
        }
        let pair = step(first) |> and_bind(step(first + 1)) |> bind
        return "{pair.first}:{pair.second}"
    }
}
def test_early_return() {
    events = ""
    let big = classify(500)
    assert(big is ok && (big as ok) == "big" && events == "")
    let seven = classify(7)
    assert(seven is err && (seven as err) == "negative -3")
    let eight = classify(8)
    assert(eight is ok && (eight as ok) == "eight")
    evaluated = 0
    let plain = classify(3)
    assert(plain is ok && (plain as ok) == "3:4" && events == "other;" && evaluated == 3)
    evaluated = 0
    let failed = classify(-1)
    assert(failed is err && (failed as err) == "negative -1" && evaluated == 1)
}

def test_tail_branches() {
    let chosen = computation(OptionBuilder()) {
        let n = maybe(4) |> bind
        if (n > 3) {
            let m = maybe(n * 2) |> bind
            return "large {m}"
        } else {
            return "small"
        }
    }
    assert(chosen is some && (chosen as some) == "large 8")
    let absent = computation(OptionBuilder()) {
        let n = maybe(4) |> bind
        if (n > 3) {
            let m = maybe(-n) |> bind
            return m
        }
        return n
    }
    assert(absent is none)
    let nested = computation(ResultBuilder()) {
        let n = step(2) |> bind
        {
            let m = step(n + 1) |> bind
            if (m == 3) { return m * 10 }
        }
        return 0
    }
    assert(nested is ok && (nested as ok) == 30)
}

def test_statements_and_steps() {
    evaluated = 0
    var seen = 0
    let looped = computation(ResultBuilder()) {
        step(1) |> bind
        for (i in range(4)) {
            let value = step(2 - i) |> bind
            seen += value
        }
        seen += 100
        return seen
    }
    // The fourth iteration fails: nothing after the loop runs.
    assert(looped is err && (looped as err) == "negative -1" && seen == 3 && evaluated == 5)
    var total = 0
    let counted = computation(ResultBuilder()) {
        var i = 0
        while (i < 3) {
            let value = step(i) |> bind
            total += value
            i++
        }
        try_finally($ { step(10) |> bind }, $ { total += 1000 })
        return total
    }
    assert(counted is ok && (counted as ok) == 1003)
    var handled = 0
    let recovered = computation(ResultBuilder()) {
        let base = step(5) |> bind
        try_with($ {
            panic("boom")
            return 1
        }, $(message : string) {
            handled++
            return base + 1
        })
    }
    assert(recovered is ok && (recovered as ok) == 6 && handled == 1)
    let unit = computation(OptionBuilder()) {
        maybe(1) |> bind
        for (i in range(2)) { maybe(i) |> bind }
    }
    assert(unit is some)
}

def test_resources() {
    events = ""
    let scoped = computation(ResultBuilder()) {
        let base = step(1) |> bind
        if (base == 1) {
            let door = open(1) |> use_resource
            events += "inside{door.id};"
        }
        events += "after;"
        let door = open(2) |> use_resource
        let value = step(base + door.id) |> bind
        return value
    }
    assert(scoped is ok && (scoped as ok) == 3)
    assert(events == "open1;inside1;close1;after;open2;close2;")
    events = ""
    let stopped = computation(ResultBuilder()) {
        let door = open(3) |> use_resource
        let value = step(-door.id) |> bind
        events += "unreachable;"
        return value
    }
    assert(stopped is err && events == "open3;close3;")
}

def test_sources() {
    events = ""
    evaluated = 0
    let adapted = computation(ResultBuilder()) {
        let a = Token(value=4) |> bind
        let b : int = step(a + 1) |> bind
        var c = Token(value=b) |> and_bind(step(1)) |> bind
        c.second += 10
        return a + b + c.first + c.second
    }
    // Each source is evaluated once and the hook runs once per Token.
    assert(adapted is ok && (adapted as ok) == 25 && events == "hook4;hook5;" && evaluated == 4)
    let forwarded = computation(ResultBuilder()) {
        let a = step(1) |> bind
        if (a == 1) { return step(-5) |> return_from }
        return Token(value=a) |> return_from
    }
    assert(forwarded is err && (forwarded as err) == "negative -5")
    let inner = computation(ResultBuilder()) {
        let outer = step(2) |> bind
        let nested = computation(OptionBuilder()) {
            let n = maybe(outer) |> bind
            return n + 1
        }
        if (nested is none) { return 0 }
        return (nested as some) * 2
    }
    assert(inner is ok && (inner as ok) == 6)
}

def test_validation() {
    let both = computation(ValidationBuilder()) {
        let pair = checked(-1) |> and_bind(checked(-2)) |> bind
        return pair.first + pair.second
    }
    assert(both is invalid && (both as invalid).count == 2)
    let early = computation(ValidationBuilder()) {
        let value = checked(3) |> bind
        if (value == 3) { return "three" }
        let other = checked(-value) |> bind
        return "{other}"
    }
    assert(early is valid && (early as valid) == "three")
    let sequential = computation(ValidationBuilder()) {
        let value = checked(-3) |> bind
        let other = checked(-4) |> bind
        return value + other
    }
    assert(sequential is invalid && (sequential as invalid).count == 1)
}

def long_chain(start : int) {
    return computation(ResultBuilder()) {
        let v0 = step(start) |> bind
        let v1 = step(v0 + 1) |> bind
        let v2 = step(v1 + 1) |> bind
        let v3 = step(v2 + 1) |> bind
        let v4 = step(v3 + 1) |> bind
        let v5 = step(v4 + 1) |> bind
        let v6 = step(v5 + 1) |> bind
        let v7 = step(v6 + 1) |> bind
        let v8 = step(v7 + 1) |> bind
        let v9 = step(v8 + 1) |> bind
        let v10 = step(v9 + 1) |> bind
        let v11 = step(v10 + 1) |> bind
        let v12 = step(v11 + 1) |> bind
        let v13 = step(v12 + 1) |> bind
        let v14 = step(v13 + 1) |> bind
        let v15 = step(v14 + 1) |> bind
        let v16 = step(v15 + 1) |> bind
        let v17 = step(v16 + 1) |> bind
        let v18 = step(v17 + 1) |> bind
        let v19 = step(v18 + 1) |> bind
        let v20 = step(v19 + 1) |> bind
        let v21 = step(v20 + 1) |> bind
        let v22 = step(v21 + 1) |> bind
        let v23 = step(v22 + 1) |> bind
        let v24 = step(v23 + 1) |> bind
        let v25 = step(v24 + 1) |> bind
        let v26 = step(v25 + 1) |> bind
        let v27 = step(v26 + 1) |> bind
        let v28 = step(v27 + 1) |> bind
        let v29 = step(v28 + 1) |> bind
        let v30 = step(v29 + 1) |> bind
        let v31 = step(v30 + 1) |> bind
        let v32 = step(v31 + 1) |> bind
        let v33 = step(v32 + 1) |> bind
        let v34 = step(v33 + 1) |> bind
        let v35 = step(v34 + 1) |> bind
        let v36 = step(v35 + 1) |> bind
        let v37 = step(v36 + 1) |> bind
        let v38 = step(v37 + 1) |> bind
        let v39 = step(v38 + 1) |> bind
        return v39
    }
}
def test_long_chain() {
    // Forty binds in one scope: twice what continuations could nest.
    evaluated = 0
    let reached = long_chain(1)
    assert(reached is ok && (reached as ok) == 40 && evaluated == 40)
    evaluated = 0
    let stopped = long_chain(-20)
    assert(stopped is err && (stopped as err) == "negative -20" && evaluated == 1)
}

[export]
def main() {
    test_early_return()
    test_tail_branches()
    test_statements_and_steps()
    test_resources()
    test_sources()
    test_validation()
    test_long_chain()
    print("direct lowering checks OK\n")
}
