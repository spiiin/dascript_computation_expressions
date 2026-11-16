options gen2
expect 30341
// diagnostic: ce_dispose
require ../packages/computation/computation.das
struct NoDisposer { id : int }
[export]
def main() {
    let bad = computation(ResultBuilder()) {
        let owned = NoDisposer(id=1) |> use_resource
        return owned.id
    }
    print("{bad}\n")
}
