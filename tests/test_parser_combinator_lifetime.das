options gen2
options stack = 1048576
require ../packages/computation/computation_macro.das
require ../packages/computation/parser_builder.das
require ../packages/computation/deferred_computation.das
require daslib/rtti
def group(cursor:ParserBuilder) {
    return <- computation(cursor) {
        parser_literal("[") |> bind
        var items & = parser_sep_by(parser_int(),parser_literal(",")) |> bind
        parser_literal("]") |> bind
        return <- items
    }
}
def empty_group(cursor:ParserBuilder) {
    var values:array<int>
    return <- parser_ok_move(values,cursor.position)
}
def check() {
    var inscope nested <- computation(ParserBuilder(text="[1,2][3]")) {
        var values & = parser_many(parser_call(@@group)) |> bind
        return <- values
    }
    assert(length((nested as parsed).value)==2 && (nested as parsed).value[0][0]==1)
    var inscope rollback <- computation(ParserBuilder(text="[1,2x")) {
        return parser_choice(parser_attempt(parser_call(@@group)),parser_call(@@empty_group)) |> return_from
    }
    assert(rollback is parsed && length((rollback as parsed).value)==0 && (rollback as parsed).position==0)
    var inscope partial <- computation(ParserBuilder(text="abax")) {return parser_many(parser_literal("ab")) |> return_from}
    assert(partial is failure)
    var inscope trailing <- computation(ParserBuilder(text="1,2,")) {return parser_sep_by(parser_int(),parser_literal(",")) |> return_from}
    assert(trailing is failure)
    var inscope optional <- computation(ParserBuilder(text="[1,2]")) {return parser_optional(parser_call(@@group)) |> return_from}
    assert(length((optional as parsed).value as some)==2)
    var inscope absent <- computation(ParserBuilder(text="x")) {return parser_optional(parser_call(@@group)) |> return_from}
    assert((absent as parsed).value is none)
    var inscope saved <- deferred(ParserBuilder(text="1,2")) {
        var items & = parser_sep_by(parser_int(),parser_literal(",")) |> bind
        return <- items
    }
    var inscope first <- run_deferred(saved)
    var inscope second <- run_deferred(saved)
    (first as parsed).value[0]=7
    assert((second as parsed).value[0]==1)
    delete saved
    assert((first as parsed).value[1]==2)
}
[export]
def main() {
    check()
    let baseline=heap_bytes_allocated()
    for(i in range(16)) {check();verify(heap_bytes_allocated()==baseline)}
    print("Parser combinator lifetime checks OK\n")
}
