options gen2
require ../packages/computation/computation.das

// A panic is fatal: nothing catches it, so there is no handler to write.
// try_with is rejected by the macro with a message that says what to do instead.
[export]
def main() {
    let result = computation(ResultBuilder()) {
        try_with($ {
            return 1
        }, $(message : string) {
            return 2
        })
    }
    print("{result}\n")
}
