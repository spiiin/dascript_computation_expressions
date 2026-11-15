options gen2
require ../packages/computation/computation.das
[export]
def main() {
    let bad = computation(ResultBuilder()) {
        return 1
        print("unreachable\n")
    }
    print("{bad}\n")
}
