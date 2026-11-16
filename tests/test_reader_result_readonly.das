options gen2
expect 30952
// diagnostic: can't write to a constant value
require ../packages/computation/computation_macro.das
require ../examples/builders/reader_result_builder.das
struct Rules {limit:int=2}
[export]
def main() {
    let value=computation(ReaderResultBuilder(Rules())) {
        let config=reader_ask() |> bind
        config.limit=99
        return config.limit
    }
}
