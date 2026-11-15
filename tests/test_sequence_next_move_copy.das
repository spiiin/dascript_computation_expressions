options gen2
expect 31400
// diagnostic: sequence_next_move requires a move-only element
require ../packages/computation/computation.das
[export]
def main() {
    var inscope stream <- computation(SequenceBuilder()) {yield 1}
    var value=0
    let more=sequence_next_move(stream,value)
}
