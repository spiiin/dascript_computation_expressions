options gen2
expect 30231
expect 50503
// diagnostic: expected 'let resource
require ../packages/computation/computation.das
[export]
def main() {
    let bad = computation(ResultBuilder()) { 42 |> use_resource }
    print("{bad}\n")
}
