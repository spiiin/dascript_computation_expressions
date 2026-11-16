options gen2
expect 30951
expect 31400
expect 31403
// diagnostic: value must be moved; use 'return <- value'
// anchor: return items
require ../packages/computation/computation.das
[export]
def main() {
    var inscope r <- computation(MoveResultBuilder()) {
        var items & = move_ok([1,2]) |> bind
        return items
    }
}
