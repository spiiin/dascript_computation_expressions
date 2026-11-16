options gen2
expect 31403
// diagnostic: and_bind is unsupported for builder
require ../packages/computation/computation_macro.das
require ../packages/computation/parser_builder.das
[export]
def main() {
    let parsed=computation(ParserBuilder(text="12")) {
        let pair=parser_int() |> and_bind(parser_int()) |> bind
        return pair
    }
}
