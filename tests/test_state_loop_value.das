options gen2
expect 30343
// diagnostic: tuple<value:int;state:int>
require ../packages/computation/computation.das
require ../examples/builders/computation_effects.das
[export]
def main() {
    let invalid = computation(StateBuilder(0)) {
        for (i in range(3)) { return i }
    }
    print("{invalid}\n")
}
