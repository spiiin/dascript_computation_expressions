options gen2
expect 30341:2
// diagnostic: and_bind
require ../packages/computation/computation.das
[export]
def main() {
    let value = computation(ResultBuilder()) { let p = result_ok(1) |> and_bind(result_ok(2)); return p }
}
