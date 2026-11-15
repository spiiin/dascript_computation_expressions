options gen2
require ../packages/computation/computation.das
[export]
def main() {
    let bad = computation(ResultBuilder()) { 42 |> use_resource }
    print("{bad}\n")
}
