options gen2
require ../packages/computation/computation_macro.das
require ../packages/computation/parser_builder.das
[export]
def main() {
    let parsed=computation(ParserBuilder(text="12")) {
        let pair=parser_int() |> and_bind(parser_int()) |> bind
        return pair
    }
}
