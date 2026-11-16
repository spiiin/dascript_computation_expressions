options gen2
expect 50503
// diagnostic: try_finally expects two blocks
require ../packages/computation/computation.das
[export]
def main() {
    let bad = computation(ResultBuilder()) { try_finally(1, 2) }
}
