options gen2
require ../packages/computation/computation.das
[export]
def main() {
    var inscope invalid <- computation(ListBuilder()) { result_ok(1) |> bind }
}
