options gen2
expect 30344
// diagnostic: initialization type mismatch
require ../packages/computation/computation.das
[export]
def main() {
    let bad = computation(OptionBuilder()) {
        let value : string = some(1) |> bind
        return value
    }
    print("{bad}\n")
}
