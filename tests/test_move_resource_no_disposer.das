options gen2
expect 30341
// diagnostic: ce_dispose
require ../packages/computation/computation.das
struct Resource {data:array<int>}
def acquire() {var r:Resource;r.data <- [1];return <- r}
[export]
def main() {
    let result=computation(ResultBuilder()) {
        var resource & = acquire() |> use_resource
        return 1
    }
}
