options gen2
expect 50503
// diagnostic: bind borrows its payload
require ../packages/computation/computation.das
[export]
def main() {
    var inscope r <- computation(MoveResultBuilder()) {
        var items <- move_ok([1,2]) |> bind
        return <- items
    }
}
