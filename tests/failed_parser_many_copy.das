options gen2
require ../packages/computation/computation_macro.das
require ../packages/computation/parser_builder.das
[export]
def main() {
    let value=computation(ParserBuilder(text="aa")) {
        let items=parser_many(parser_literal("a")) |> bind
        return length(items)
    }
}
