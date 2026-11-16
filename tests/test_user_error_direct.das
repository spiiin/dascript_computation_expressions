options gen2
expect 30316
expect 30341
expect 30820
expect 30838
// diagnostic: can't locate variable 'missing_direct'
// anchor: missing_direct
// first
require ../packages/computation/computation.das

def half(value : int) : Result<int;string> {
    return value % 2 == 0 ? ok(value / 2, type<string>) : err("odd", type<int>)
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
}
