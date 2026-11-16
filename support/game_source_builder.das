options gen2
module game_source_builder public
require ../packages/computation/computation_builders.das public

struct GameSourceBuilder { minimumHealth:int=1 }
def ce_protocol(builder:GameSourceBuilder) { return CeValueProtocol() }
def ce_unwrap(builder:GameSourceBuilder; source:Result<auto(TT);string>) : TT { return source as ok }
def ce_return(builder:GameSourceBuilder; value:auto) { return ce_return(ResultBuilder(),value) }
def ce_return_from(builder:GameSourceBuilder; source:Result<auto(TT);string>) { return source }
def ce_zero(builder:GameSourceBuilder) { return ce_zero(ResultBuilder()) }
def ce_bind(builder:GameSourceBuilder; source:Result<auto(TT);string>; next:block<(value:TT):auto(RR)>) : RR {
    return ce_bind(ResultBuilder(),source,next)
}
def ce_combine(builder:GameSourceBuilder; first:Result<CeUnit;string>; next:block<():auto(RR)>) : RR {
    return ce_combine(ResultBuilder(),first,next)
}
def ce_loop_failed(builder:GameSourceBuilder; step:Result<CeUnit;string>) : bool { return ce_loop_failed(ResultBuilder(),step) }
def ce_loop_append(builder:GameSourceBuilder; first,step:Result<CeUnit;string>) { return ce_loop_append(ResultBuilder(),first,step) }
def ce_merge_sources(builder:GameSourceBuilder; left:Result<auto(AA);string>; right:Result<auto(BB);string>) {
    return ce_merge_sources(ResultBuilder(),left,right)
}
def ce_bind_return(builder:GameSourceBuilder; source:Result<auto(TT);string>; mapper:block<(value:TT):auto(UU)>) {
    return ce_bind_return(ResultBuilder(),source,mapper)
}
def ce_bind2_return(builder:GameSourceBuilder; left:Result<auto(AA);string>; right:Result<auto(BB);string>;
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):auto(UU)>) {
    return ce_bind2_return(ResultBuilder(),left,right,mapper)
}
def ce_bind2(builder:GameSourceBuilder; left:Result<auto(AA);string>; right:Result<auto(BB);string>;
             next:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):auto(RR)>) : RR {
    return ce_bind2(ResultBuilder(),left,right,next)
}

struct HealthCheck {health:int}
struct TargetRange {first:int; count:int}
def ce_source(builder:GameSourceBuilder; request:HealthCheck) {
    if (request.health<builder.minimumHealth) {return err("not enough health",type<int>)}
    return ok(request.health, type<string>)
}
def ce_source(builder:GameSourceBuilder; request:TargetRange) {
    return range(request.first,request.first+request.count)
}
