options gen2
require dastest/testing_boost public
require ../packages/computation/computation_macro.das
require ../examples/builders/reader_builder.das

var merged = 0
def ce_merge_sources(builder : tuple<kind:ReaderContext;environment:auto(EE)>;
                     left : tuple<value:auto(AA)>; right : tuple<value:auto(BB)>) {
    merged++
    return reader_value(ce_source_pair(left.value, right.value))
}
[export]
def main() {
    let result = computation(ReaderBuilder(0)) {
        let pair = reader_value(5) |> and_bind(reader_value("external")) |> bind
        return "{pair.second}:{pair.first}"
    }
    assert(result.value == "external:5" && merged == 1)
    print("and_bind external protocol OK\n")
}

[test]
def test_and_bind_external() {
    main()
}
