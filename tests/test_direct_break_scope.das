options gen2
require ../lib/computation.das

struct Resource {
    id : int
}
def ce_dispose(var resource : Resource) {}

// After use_resource the rest of the body is the resource's own scope, a block
// handed to the builder. A break there cannot reach the loop around it.
[export]
def main() {
    let result = computation(ResultBuilder()) {
        for (i in range(3)) {
            let resource = Resource(id = i) |> use_resource
            if (i == 1) { break }
        }
    }
    print("{result}\n")
}
