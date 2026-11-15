options gen2
require ../packages/computation/computation.das

// A break with no loop around it is rejected by the macro.
[export]
def main() {
    let result = computation(ResultBuilder()) {
        try_with($ {
            break
        }, $(message : string) {
        })
    }
    print("{result}\n")
}
