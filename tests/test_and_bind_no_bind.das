options gen2
expect 30341:2
// diagnostic: and_bind
require ../packages/computation/computation.das
[export]
def main() {
    let value = computation(ResultBuilder()) { let p = ok(1, type<string>) |> and_bind(ok(2, type<string>)); return p }
}
