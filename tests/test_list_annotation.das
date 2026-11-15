options gen2
require ../packages/computation/computation.das
[export]
def main() {
    var inscope invalid <- computation(ListBuilder()) {
        let x : string = [1, 2] |> bind
        return 42
    }
}
