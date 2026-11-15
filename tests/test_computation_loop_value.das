options gen2
require ../packages/computation/computation.das
[export]
def main() {
    let bad = computation(ResultBuilder()) {
        for (i in range(3)) { return i }
    }
    print("{bad}\n")
}
