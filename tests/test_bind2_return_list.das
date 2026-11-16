options gen2
require dastest/testing_boost public
require ../packages/computation/computation.das

var fastBytes=0ul
var slowBytes=0ul
def observe(p:tuple<first:int;second:int>; fast:bool) {
    if (p.first==0 && p.second==0) {
        if (fast) { fastBytes=heap_bytes_allocated() } else { slowBytes=heap_bytes_allocated() }
    }
    return p.first+p.second
}
def mutate(var left,right:array<int>; p:tuple<first:int;second:int>) {
    clear(left)
    clear(right)
    return p.first+p.second
}
[export]
def main() {
    let baseline=heap_bytes_allocated()
    {
        var inscope left:array<int>
        var inscope right:array<int>
        for(i in range(64)) { left |> push(i); right |> push(i) }
        {
            var inscope fast <- computation(ListBuilder(type<int>)) { let p=left |> and_bind(right) |> bind; return observe(p,true) }
            assert(length(fast)==4096 && fast[0]==0 && fast[4095]==126)
        }
        {
            var inscope merged <- ce_merge_sources(ListBuilder(type<int>),left,right)
            var inscope slow <- computation(ListBuilder(type<int>)) { let p=merged |> bind; let unused=0; return observe(p,false) }
            assert(length(slow)==4096 && slow[0]==0 && slow[4095]==126)
        }
        assert(fastBytes<slowBytes && length(left)==64 && length(right)==64)
    }
    {
        var inscope left <- [1,2]
        var inscope right <- [10,20]
        var inscope values <- computation(ListBuilder(type<int>)) { let p=left |> and_bind(right) |> bind; return mutate(left,right,p) }
        assert(length(left)==0 && length(right)==0)
        assert(length(values)==4 && values[0]==11 && values[1]==21 && values[2]==12 && values[3]==22)
    }
    let after=heap_bytes_allocated()
    assert(after==baseline)
    print("bind2_return list checks OK: heap before first map {fastBytes} < {slowBytes}\n")
}

[test]
def test_bind2_return_list() {
    main()
}
