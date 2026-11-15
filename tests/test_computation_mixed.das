options gen2
expect 31400
// diagnostic: ce_unwrap
// diagnostic: cannot bind a source of type variant<none;some:int>
// anchor: |> bind
require ../packages/computation/computation.das
[export]
def main() {
    let bad = computation(ResultBuilder()) {
        let value = some(1) |> bind
        return value
    }
    print("{bad}\n")
}
