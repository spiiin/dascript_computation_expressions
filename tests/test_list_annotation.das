options gen2
expect 30344
// diagnostic: initialization type mismatch
require ../packages/computation/computation.das
[export]
def main() {
    var inscope invalid <- computation(ListBuilder(type<int>)) {
        let x : string = [1, 2] |> bind
        return 42
    }
}
