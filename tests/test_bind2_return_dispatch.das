options gen2
require dastest/testing_boost public
require ../packages/computation/computation_macro.das
struct Probe {}
struct Legacy {}
var merges=0
var binds=0
var returns=0
var ones=0
var twos=0
var order=""
def source(n:int) { order+="{n}"; return (value=n) }
def ce_protocol(builder:Probe) { return CeValueProtocol() }
def ce_protocol(builder:Legacy) { return CeValueProtocol() }
def ce_unwrap(builder:Probe; value:tuple<value:auto(TT)>) : TT { return value.value }
def ce_unwrap(builder:Legacy; value:tuple<value:auto(TT)>) : TT { return value.value }
def ce_return(builder:Probe; value:auto(TT)) { returns++; return (value=value) }
def ce_return(builder:Legacy; value:auto(TT)) { returns++; return (value=value) }
def ce_bind(builder:Probe; value:tuple<value:auto(TT)>; next:block<(x:TT):auto(RR)>) : RR { binds++; return invoke(next,value.value) }
def ce_bind(builder:Legacy; value:tuple<value:auto(TT)>; next:block<(x:TT):auto(RR)>) : RR { binds++; return invoke(next,value.value) }
def ce_merge_sources(builder:Probe; left:tuple<value:auto(AA)>; right:tuple<value:auto(BB)>) {
    merges++; return (value=ce_source_pair(left.value,right.value))
}
def ce_merge_sources(builder:Legacy; left:tuple<value:auto(AA)>; right:tuple<value:auto(BB)>) {
    merges++; return (value=ce_source_pair(left.value,right.value))
}
def ce_bind_return(builder:Probe; value:tuple<value:auto(TT)>; mapper:block<(x:TT):auto(UU)>) {
    ones++; return (value=invoke(mapper,value.value))
}
def ce_bind2_return(builder:Probe; left:tuple<value:auto(AA)>; right:tuple<value:auto(BB)>;
                    mapper:block<(p:tuple<first:AA -const -&;second:BB -const -&>):auto(UU)>) {
    twos++; return (value=invoke(mapper,ce_source_pair(left.value,right.value)))
}
[export]
def main() {
    let fast=computation(Probe()) { let p=source(1) |> and_bind(source(2)) |> bind; return p.first+p.second }
    assert(fast.value==3 && order=="12" && twos==1 && merges==0 && ones==0 && binds==0 && returns==0)
    let slow=computation(Probe()) { let p=source(3) |> and_bind(source(4)) |> bind; let unused=0; return p.first+p.second }
    assert(slow.value==7 && order=="1234" && twos==1 && merges==1 && binds==1 && returns==1)
    let triple=computation(Probe()) { let p=source(5) |> and_bind(source(6)) |> and_bind(source(7)) |> bind; return p.first.first+p.first.second+p.second }
    assert(triple.value==18 && order=="1234567" && twos==2 && merges==2 && ones==0)
    let legacy=computation(Legacy()) { let p=source(8) |> and_bind(source(9)) |> bind; return p.first+p.second }
    assert(legacy.value==17 && order=="123456789" && twos==2 && merges==3 && binds==2 && returns==2)
    let discarded=computation(Probe()) { source(1) |> and_bind(source(2)) |> bind; return 5 }
    assert(discarded.value==5 && twos==3 && merges==3)
    print("bind2_return dispatch checks OK\n")
}

[test]
def test_bind2_return_dispatch() {
    main()
}
