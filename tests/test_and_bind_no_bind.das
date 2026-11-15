options gen2
require ../packages/computation/computation.das
[export]
def main() {
    let value = computation(ResultBuilder()) { let p = result_ok(1) |> and_bind(result_ok(2)); return p }
    print("{value}")
}
