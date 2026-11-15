options gen2
expect 30231
expect 50503
// diagnostic: expected 'left |> and_bind(right) |> bind'
require ../packages/computation/computation.das
[export]
def main() {
    let value = computation(ResultBuilder()) { let p = result_ok(1) |> and_bind() |> bind; return p }
    print("{value}")
}
