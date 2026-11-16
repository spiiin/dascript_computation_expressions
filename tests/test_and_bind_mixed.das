options gen2
expect 31403
// diagnostic: ce_merge_sources
// diagnostic: and_bind is unsupported for builder
// anchor: and_bind
require ../packages/computation/computation.das
[export]
def main() {
    let value = computation(ResultBuilder()) { let p = ok(1, type<string>) |> and_bind(some(2)) |> bind; return p }
    print("{value}")
}
