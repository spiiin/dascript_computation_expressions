options gen2
expect 31400
// diagnostic: variant<none;some:int>
require ../packages/computation/computation.das
[export]
def main() {
    let bad = computation(ResultBuilder()) {
        for (i in range(3)) { some(i) |> bind }
    }
    print("{bad}\n")
}
