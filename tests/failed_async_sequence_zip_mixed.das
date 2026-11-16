options gen2
expect 31400
// diagnostic: cannot mix AsyncSequence and native sources
require ../packages/computation/computation_macro.das
require ../packages/computation_task/async_sequence_builder.das
def numbers() {return <- computation(AsyncSequenceBuilder(type<int>)) {yield 1}}
[export]
def main() {
    var inscope stream <- computation(AsyncSequenceBuilder(type<int>)) {
        for(a,b in numbers(),range(2)) {yield a+b}
    }
}
