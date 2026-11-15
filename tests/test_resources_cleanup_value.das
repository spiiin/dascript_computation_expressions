options gen2
require ../packages/computation/computation.das
[export]
def main() {
    let bad = computation(ResultBuilder()) {
        try_finally($ { return 42 }, $ { return 1 })
    }
    print("{bad}\n")
}
