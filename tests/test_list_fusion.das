options gen2
require dastest/testing_boost public
require ../packages/computation/computation.das
require ../benchmarks/list_benchmark_workloads.das
require daslib/rtti
var trace=""
var live=0
var right=fixed_array(3,4)
struct Owned {
    payload:array<int>
    def finalize {
        if(length(payload)>0) {trace+="D{payload[0]};";live--}
        else {trace+="E;"}
        delete payload
    }
}
def items(first,count:int) {
    var inscope values:array<Owned>
    for(i in range(count)) {
        var inscope item:Owned
        item.payload |> push(first+i);live++
        values |> emplace(item)
    }
    return <- values
}
def transfer(var item:Owned) {
    trace+="M{item.payload[0]};"
    return <- item
}
def owned_case(fast,nested:bool) {
    let baseline=heap_bytes_allocated()
    {
        var inscope source <- items(1,3)
        var inscope result:array<Owned>
        if(nested) {
            if(fast) {
                result <- computation(ListBuilder(type<Owned>)) {
                    var a & = source |> bind
                    var b & = items(a.payload[0]*10,2) |> bind
                    return <- transfer(b)
                }
            } else {
                result <- computation(ListBuilder(type<Owned>)) {
                    var a & = source |> bind
                    var b & = items(a.payload[0]*10,2) |> bind
                    let barrier=0
                    return <- transfer(b)
                }
            }
        } else {
            if(fast) {
                result <- computation(ListBuilder(type<Owned>)) {
                    var a & = source |> bind
                    return <- transfer(a)
                }
            } else {
                result <- computation(ListBuilder(type<Owned>)) {
                    var a & = source |> bind
                    let barrier=0
                    return <- transfer(a)
                }
            }
        }
        assert(length(source)==0)
        assert(length(result)==(nested ? 6 : 3))
    }
    assert(live==0)
    let current=heap_bytes_allocated();assert(current==baseline)
}
def second(a:int) {trace+="S{a};";return right}
def mapped(a,b:int) {
    trace+="V{a},{b};";right[0]++
    return a*10+b
}
def copy_case(fast,emptySource:bool) {
    let baseline=heap_bytes_allocated()
    {
        var inscope left:array<int>
        if(!emptySource) {left |> push(1);left |> push(2)}
        var inscope output:array<int>
        if(fast) {
            output <- computation(ListBuilder()) {
                let a=left |> bind
                let b=second(a) |> bind
                return mapped(a,b)
            }
        } else {
            output <- computation(ListBuilder()) {
                let a=left |> bind
                let barrier=0
                let b=second(a) |> bind
                return mapped(a,b)
            }
        }
        trace+="O{output};"
    }
    let current=heap_bytes_allocated();assert(current==baseline)
}

struct Wrapped {value:Owned}
[export]
def main() {
    assert(typeinfo ce_has_collect_sink(ce_collect_sink(ListBuilder(type<BenchOwned>))))
    assert(!(typeinfo ce_has_collect_sink(ce_collect_sink(ListBuilder(type<Owned>)))))
    assert(!(typeinfo ce_has_collect_sink(ce_collect_sink(ListBuilder(type<Wrapped>)))))
    {
        var inscope triple <- computation(ListBuilder()) {
            let a=fixed_array(1,2) |> bind
            fixed_array(0,0) |> bind
            let b=fixed_array(3,4) |> bind
            return a*10+b
        }
        assert(length(triple)==8 && triple[0]==13 && triple[7]==24)
    }

    for(emptySource in fixed_array(false,true)) {
        trace="";right=fixed_array(3,4);copy_case(false,emptySource)
        let expected=trace
        trace="";right=fixed_array(3,4);copy_case(true,emptySource)
        assert(trace==expected)
    }
    for(nested in fixed_array(false,true)) {
        trace="";owned_case(false,nested);let expected=trace
        trace="";owned_case(true,nested);assert(trace==expected)
    }
    print("List fusion effects and ownership OK\n")
}

[test]
def test_list_fusion() {
    main()
}
