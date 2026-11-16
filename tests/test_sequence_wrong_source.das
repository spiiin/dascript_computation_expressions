options gen2
expect 31403
// diagnostic: a sequence cannot bind a source of type variant<err:string;ok:int>
// anchor: |> bind
require ../packages/computation/computation.das
require ../packages/computation/sequence_builder.das

// A sequence's bind walks its source. A Result is not something to walk, and
// that is reported once, at the bind, rather than as the three errors of the
// loop the bind turns into.
[export]
def main() {
    var inscope numbers <- computation(SequenceBuilder(type<int>)) {
        let value = ok(1, type<string>) |> bind
        yield value
    }
}
