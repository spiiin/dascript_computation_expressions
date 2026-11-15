options gen2
require ../lib/computation.das
require ../examples/builders/computation_effects.das

// How many binds one scope holds when every source uses the value before it.
// Each such bind costs the compiler inference passes, and a builder lowered
// with continuations also two levels of calls; both are limited. These
// chains are a little under the limits, so a change that makes a bind
// dearer fails here instead of in somebody's longer function.

def continuations() {
    return computation(WriterBuilder()) {
        let v0 = writer_value(1, "") |> bind
        let v1 = writer_value(v0 + 1, "") |> bind
        let v2 = writer_value(v1 + 1, "") |> bind
        let v3 = writer_value(v2 + 1, "") |> bind
        let v4 = writer_value(v3 + 1, "") |> bind
        let v5 = writer_value(v4 + 1, "") |> bind
        let v6 = writer_value(v5 + 1, "") |> bind
        let v7 = writer_value(v6 + 1, "") |> bind
        let v8 = writer_value(v7 + 1, "") |> bind
        let v9 = writer_value(v8 + 1, "") |> bind
        let v10 = writer_value(v9 + 1, "") |> bind
        let v11 = writer_value(v10 + 1, "") |> bind
        let v12 = writer_value(v11 + 1, "") |> bind
        let v13 = writer_value(v12 + 1, "") |> bind
        let v14 = writer_value(v13 + 1, "") |> bind
        let v15 = writer_value(v14 + 1, "") |> bind
        let v16 = writer_value(v15 + 1, "") |> bind
        let v17 = writer_value(v16 + 1, "") |> bind
        let v18 = writer_value(v17 + 1, "") |> bind
        let v19 = writer_value(v18 + 1, "") |> bind
        return v19
    }
}

def direct() {
    return computation(ResultBuilder()) {
        let v0 = result_ok(1) |> bind
        let v1 = result_ok(v0 + 1) |> bind
        let v2 = result_ok(v1 + 1) |> bind
        let v3 = result_ok(v2 + 1) |> bind
        let v4 = result_ok(v3 + 1) |> bind
        let v5 = result_ok(v4 + 1) |> bind
        let v6 = result_ok(v5 + 1) |> bind
        let v7 = result_ok(v6 + 1) |> bind
        let v8 = result_ok(v7 + 1) |> bind
        let v9 = result_ok(v8 + 1) |> bind
        let v10 = result_ok(v9 + 1) |> bind
        let v11 = result_ok(v10 + 1) |> bind
        let v12 = result_ok(v11 + 1) |> bind
        let v13 = result_ok(v12 + 1) |> bind
        let v14 = result_ok(v13 + 1) |> bind
        let v15 = result_ok(v14 + 1) |> bind
        let v16 = result_ok(v15 + 1) |> bind
        let v17 = result_ok(v16 + 1) |> bind
        let v18 = result_ok(v17 + 1) |> bind
        let v19 = result_ok(v18 + 1) |> bind
        let v20 = result_ok(v19 + 1) |> bind
        let v21 = result_ok(v20 + 1) |> bind
        let v22 = result_ok(v21 + 1) |> bind
        let v23 = result_ok(v22 + 1) |> bind
        let v24 = result_ok(v23 + 1) |> bind
        let v25 = result_ok(v24 + 1) |> bind
        let v26 = result_ok(v25 + 1) |> bind
        let v27 = result_ok(v26 + 1) |> bind
        let v28 = result_ok(v27 + 1) |> bind
        let v29 = result_ok(v28 + 1) |> bind
        let v30 = result_ok(v29 + 1) |> bind
        let v31 = result_ok(v30 + 1) |> bind
        let v32 = result_ok(v31 + 1) |> bind
        let v33 = result_ok(v32 + 1) |> bind
        let v34 = result_ok(v33 + 1) |> bind
        let v35 = result_ok(v34 + 1) |> bind
        let v36 = result_ok(v35 + 1) |> bind
        let v37 = result_ok(v36 + 1) |> bind
        let v38 = result_ok(v37 + 1) |> bind
        let v39 = result_ok(v38 + 1) |> bind
        return v39
    }
}

[export]
def main() {
    verify(continuations().value == 20)
    let chained = direct()
    verify(chained is ok && (chained as ok) == 40)
    print("bind chain length checks OK
")
}
