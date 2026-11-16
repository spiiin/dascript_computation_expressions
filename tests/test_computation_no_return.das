options gen2
require dastest/testing_boost public
require ../packages/computation/computation.das
[export]
def main() {
    let value = computation(ResultBuilder()) {
        ok(1, type<string>) |> bind
    }
    assert(value is ok)
    print("no return: successful Unit OK\n")
}

[test]
def test_computation_no_return() {
    main()
}
