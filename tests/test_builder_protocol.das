options gen2
require ../packages/computation/computation_macro.das
require ../support/protocol_test_builders.das
require ../support/protocol_collect_fixture.das

var closes = 0
var steps = 0
struct Resource {}
def ce_dispose(var resource : Resource) { closes++ }
[export]
def main() {
    var inscope totals <- computation(ExternalCollectionBuilder()) {
        yield 1
        for (i in range(4)) { yield i }
        if (true) { yield 10 }
        [20] |> yield_from
    }
    var total = 0
    for (value in totals) { total += value }
    assert(total == 37)
    {
        var inscope values <- computation(custom_sequence()) {
            let resource = Resource() |> use_resource
            steps++
            yield "one"
            steps++
            yield "two"
        }
        assert(sequenceConstructors == 1 && sequenceRuns == 1 && steps == 0)
        for (value in values) { assert(value == "one"); break }
        assert(closes == 1 && steps == 1)
    }
    {
        var inscope values <- computation(custom_sequence()) { yield "complete" }
        for (value in values) { assert(value == "complete") }
    }
    assert(sequenceConstructors == 2 && sequenceRuns == 2)
    assert(protocolCalls == 0)
    print("builder protocol checks OK\n")
}

