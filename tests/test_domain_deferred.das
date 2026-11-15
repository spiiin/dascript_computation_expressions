options gen2
require ../packages/computation/computation_macro.das
require ../packages/computation/parser_builder.das
require ../packages/computation/search_builder.das
require ../examples/builders/query_builder.das
require ../packages/computation/deferred_computation.das
require daslib/rtti
def check() {
    var inscope parser <- deferred(ParserBuilder(text="42")) {
        let n=parser_int() |> bind
        parser_eof() |> bind
        return n
    }
    let p1=run_deferred(parser)
    let p2=run_deferred(parser)
    assert((p1 as parsed).value==42 && (p2 as parsed).value==42)
    var inscope query <- deferred(QueryBuilder(),3) $(count) {
        for(i in range(count)) {yield i+1}
    }
    var inscope q1 <- run_deferred(query)
    var inscope q2 <- run_deferred(query)
    assert(length(q1)==3 && length(q2)==3 && q1[0]==1 && q2[2]==3)
    var inscope search <- deferred(SearchBuilder(),3) $(count) {
        for(i in range(count)) {yield i+1}
    }
    var inscope s1 <- run_deferred(search)
    var inscope s2 <- run_deferred(search)
    delete search
    var sum=0
    sequence_each(s1) $(n:int) {sum+=n}
    sequence_each(s2) $(n:int) {sum+=n}
    assert(sum==12)
}
[export]
def main() {
    check()
    let baseline=heap_bytes_allocated()
    for(i in range(10)) {check();verify(heap_bytes_allocated()==baseline)}
    print("Domain deferred checks OK\n")
}
