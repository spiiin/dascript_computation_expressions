options gen2
expect 31403
// diagnostic: ce_unwrap
// diagnostic: cannot bind a source of type variant<err:string;ok:int>
// anchor: |> bind
require ../packages/computation/computation.das
require ../examples/builders/computation_effects.das
[export]
def main() {
    let invalid = computation(WriterBuilder()) {
        ok(1, type<string>) |> bind
    }
    print("{invalid}\n")
}
