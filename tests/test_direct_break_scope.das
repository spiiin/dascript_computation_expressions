options gen2
expect 50503
// diagnostic: break and continue need a loop around them
require ../packages/computation/computation.das

// A break with no loop around it is rejected by the macro.
[export]
def main() {
    let result = computation(ResultBuilder()) {
        try_finally($ {
            break
        }, $ {
        })
    }
}
