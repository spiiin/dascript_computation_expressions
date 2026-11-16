options gen2
module report_builder public
require ../packages/computation/computation_builders.das public

struct ReportBuilder { title:string }
def ce_protocol(builder:ReportBuilder) { return CeValueProtocol() }
def ce_unwrap(builder:ReportBuilder; source:Result<auto(TT);string>) : TT { return source as ok }
def ce_return(builder:ReportBuilder; value:auto) { return ce_return(ResultBuilder(),value) }
def ce_return_from(builder:ReportBuilder; source:Result<auto(TT);string>) { return source }
def ce_zero(builder:ReportBuilder) { return ce_zero(ResultBuilder()) }
def ce_bind(builder:ReportBuilder; source:Result<auto(TT);string>; next:block<(value:TT):auto(RR)>) : RR {
    return ce_bind(ResultBuilder(),source,next)
}
def ce_combine(builder:ReportBuilder; first:Result<CeUnit;string>; next:block<():auto(RR)>) : RR {
    return ce_combine(ResultBuilder(),first,next)
}
def ce_loop_failed(builder:ReportBuilder; step:Result<CeUnit;string>) : bool { return ce_loop_failed(ResultBuilder(),step) }
def ce_loop_append(builder:ReportBuilder; first,step:Result<CeUnit;string>) { return ce_loop_append(ResultBuilder(),first,step) }
def ce_merge_sources(builder:ReportBuilder; left:Result<auto(AA);string>; right:Result<auto(BB);string>) {
    return ce_merge_sources(ResultBuilder(),left,right)
}
def ce_bind_return(builder:ReportBuilder; source:Result<auto(TT);string>; mapper:block<(value:TT):auto(UU)>) {
    return ce_bind_return(ResultBuilder(),source,mapper)
}
def ce_bind2_return(builder:ReportBuilder; left:Result<auto(AA);string>; right:Result<auto(BB);string>;
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):auto(UU)>) {
    return ce_bind2_return(ResultBuilder(),left,right,mapper)
}
def ce_bind2(builder:ReportBuilder; left:Result<auto(AA);string>; right:Result<auto(BB);string>;
             next:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):auto(RR)>) : RR {
    return ce_bind2(ResultBuilder(),left,right,next)
}
// Only the outer CE boundary converts the internal Result into a public report.
def ce_run(builder:ReportBuilder; outcome:Result<auto(TT);string>) : variant<completed:tuple<title:string;value:TT -const -&>;failed:tuple<title:string;message:string>> {
    if (outcome is err) { return variant<completed:tuple<title:string;value:TT -const -&>;failed:tuple<title:string;message:string>>(failed=(title=builder.title,message=outcome as err)) }
    return variant<completed:tuple<title:string;value:TT -const -&>;failed:tuple<title:string;message:string>>(completed=(title=builder.title,value=outcome as ok))
}
