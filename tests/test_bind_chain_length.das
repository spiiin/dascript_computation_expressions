options gen2
require dastest/testing_boost public
require ../packages/computation/computation.das
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
        let v0 = ok(1, type<string>) |> bind
        let v1 = ok(v0 + 1, type<string>) |> bind
        let v2 = ok(v1 + 1, type<string>) |> bind
        let v3 = ok(v2 + 1, type<string>) |> bind
        let v4 = ok(v3 + 1, type<string>) |> bind
        let v5 = ok(v4 + 1, type<string>) |> bind
        let v6 = ok(v5 + 1, type<string>) |> bind
        let v7 = ok(v6 + 1, type<string>) |> bind
        let v8 = ok(v7 + 1, type<string>) |> bind
        let v9 = ok(v8 + 1, type<string>) |> bind
        let v10 = ok(v9 + 1, type<string>) |> bind
        let v11 = ok(v10 + 1, type<string>) |> bind
        let v12 = ok(v11 + 1, type<string>) |> bind
        let v13 = ok(v12 + 1, type<string>) |> bind
        let v14 = ok(v13 + 1, type<string>) |> bind
        let v15 = ok(v14 + 1, type<string>) |> bind
        let v16 = ok(v15 + 1, type<string>) |> bind
        let v17 = ok(v16 + 1, type<string>) |> bind
        let v18 = ok(v17 + 1, type<string>) |> bind
        let v19 = ok(v18 + 1, type<string>) |> bind
        let v20 = ok(v19 + 1, type<string>) |> bind
        let v21 = ok(v20 + 1, type<string>) |> bind
        let v22 = ok(v21 + 1, type<string>) |> bind
        let v23 = ok(v22 + 1, type<string>) |> bind
        let v24 = ok(v23 + 1, type<string>) |> bind
        let v25 = ok(v24 + 1, type<string>) |> bind
        let v26 = ok(v25 + 1, type<string>) |> bind
        let v27 = ok(v26 + 1, type<string>) |> bind
        let v28 = ok(v27 + 1, type<string>) |> bind
        let v29 = ok(v28 + 1, type<string>) |> bind
        let v30 = ok(v29 + 1, type<string>) |> bind
        let v31 = ok(v30 + 1, type<string>) |> bind
        let v32 = ok(v31 + 1, type<string>) |> bind
        let v33 = ok(v32 + 1, type<string>) |> bind
        let v34 = ok(v33 + 1, type<string>) |> bind
        let v35 = ok(v34 + 1, type<string>) |> bind
        let v36 = ok(v35 + 1, type<string>) |> bind
        let v37 = ok(v36 + 1, type<string>) |> bind
        let v38 = ok(v37 + 1, type<string>) |> bind
        let v39 = ok(v38 + 1, type<string>) |> bind
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

[test]
def test_bind_chain_length() {
    main()
}
