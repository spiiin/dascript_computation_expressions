options gen2
expect 31403
// diagnostic: ce_merge_sources
// diagnostic: and_bind is unsupported for builder
// anchor: and_bind
require ../packages/computation/computation_macro.das
require ../examples/builders/reader_builder.das
[export]
def main() {
    let value = computation(ReaderBuilder(0)) { let p = reader_value(1) |> and_bind(reader_value(2)) |> bind; return p }
    print("{value}")
}
