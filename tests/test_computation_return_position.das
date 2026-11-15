options gen2
expect 30231
expect 50503
// diagnostic: return must be the final statement
require ../packages/computation/computation.das
[export]
def main() {
    let bad = computation(ResultBuilder()) {
        return 1
        print("unreachable\n")
    }
    print("{bad}\n")
}
