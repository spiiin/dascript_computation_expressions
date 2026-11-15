options gen2
expect 30341
// diagnostic: ce_return
require ../packages/computation/computation.das
[export]
def main() {
    var inscope invalid <- computation(ListBuilder(type<string>)) { return 42 }
}
