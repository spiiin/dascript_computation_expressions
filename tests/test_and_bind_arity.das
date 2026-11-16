options gen2
expect 50503
// diagnostic: expected 'left |> and_bind(right) |> bind'
require ../packages/computation/computation.das
[export]
def main() {
    let value = computation(ResultBuilder()) { let p = ok(1, type<string>) |> and_bind() |> bind; return p }
}
