options gen2
require ../packages/computation/computation_macro.das
require ../packages/computation_task/async_sequence_builder.das
def numbers() {return <- computation(AsyncSequenceBuilder()) {yield 1}}
[export]
def main() {
    var inscope stream <- computation(AsyncSequenceBuilder()) {
        for(a,b in numbers(),range(2)) {yield a+b}
    }
}
