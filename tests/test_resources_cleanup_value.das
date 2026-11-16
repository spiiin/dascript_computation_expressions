options gen2
expect 30341
// diagnostic: ce_try_finally
require ../packages/computation/computation.das
[export]
def main() {
    let bad = computation(ResultBuilder()) {
        try_finally($ { return 42 }, $ { return 1 })
    }
}
