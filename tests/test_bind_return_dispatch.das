options gen2
require dastest/testing_boost public
require ../packages/computation/computation_macro.das
require ../packages/computation/builder_protocol.das

struct ProbeBuilder {}
struct LegacyBuilder {}
var binds=0
var returns=0
var fused=0
var maps=0
var sources=0

def ce_protocol(builder:ProbeBuilder) { return CeValueProtocol() }
def ce_protocol(builder:LegacyBuilder) { return CeValueProtocol() }
def source() { sources++; return (value=5) }
def mapped(value:int) { maps++; return value+1 }
def ce_unwrap(builder:ProbeBuilder; value:tuple<value:auto(TT)>) : TT { return value.value }
def ce_unwrap(builder:LegacyBuilder; value:tuple<value:auto(TT)>) : TT { return value.value }
def ce_return(builder:ProbeBuilder; value:auto(TT)) { returns++; return (value=value) }
def ce_return(builder:LegacyBuilder; value:auto(TT)) { returns++; return (value=value) }
def ce_return_from(builder:ProbeBuilder; value:tuple<value:auto(TT)>) { return value }
def ce_bind(builder:ProbeBuilder; value:tuple<value:auto(TT)>; next:block<(value:TT):auto(RR)>) : RR {
    binds++; return invoke(next,value.value)
}
def ce_bind(builder:LegacyBuilder; value:tuple<value:auto(TT)>; next:block<(value:TT):auto(RR)>) : RR {
    binds++; return invoke(next,value.value)
}
def ce_bind_return(builder:ProbeBuilder; value:tuple<value:auto(TT)>; mapper:block<(value:TT):auto(UU)>) {
    fused++; return (value=invoke(mapper,value.value))
}
[export]
def main() {
    let fast=computation(ProbeBuilder()) { let x=source() |> bind; return mapped(x) }
    assert(fast.value==6 && sources==1 && maps==1 && fused==1 && binds==0 && returns==0)
    let discard=computation(ProbeBuilder()) { source() |> bind; return 9 }
    assert(discard.value==9 && fused==2 && sources==2)
    let chain=computation(ProbeBuilder()) {
        let a=source() |> bind
        let b=source() |> bind
        return a+b
    }
    assert(chain.value==10 && fused==3 && binds==1 && returns==0 && sources==4)
    let ordinary=computation(ProbeBuilder()) { let x=source() |> bind; maps++; return x }
    assert(ordinary.value==5 && fused==3 && binds==2 && returns==1 && maps==2)
    let forwarded=computation(ProbeBuilder()) { let x=source() |> bind; return (value=x) |> return_from }
    assert(forwarded.value==5 && fused==3 && binds==3 && returns==1)
    let legacy=computation(LegacyBuilder()) { let x=source() |> bind; return mapped(x) }
    assert(legacy.value==6 && fused==3 && binds==4 && returns==2 && maps==3)
    print("bind_return dispatch checks OK\n")
}

[test]
def test_bind_return_dispatch() {
    main()
}
