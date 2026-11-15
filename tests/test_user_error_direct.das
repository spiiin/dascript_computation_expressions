options gen2
require ../lib/computation.das

def half(value : int) : Result<int;string> {
    return value % 2 == 0 ? result_ok(value / 2) : result_error("odd", type<int>)
}

// A mistake in the body is reported before anything about the code the macro
// wraps around it: the compiler prints errors in source order, and that code
// is placed at the end of the computation.
[export]
def main() {
    let result = computation(ResultBuilder()) {
        let a = half(8) |> bind
        let b = half(a) |> bind
        return a + b + missing_direct
    }
    print("{result}\n")
}
