options gen2
module identity_builder public
require computation/builder_protocol public
struct IdentityBuilder {}
def ce_protocol(builder:IdentityBuilder) {return CeValueProtocol()}
def ce_unwrap(builder:IdentityBuilder; source:tuple<value:auto(TT)>) : TT {return source.value}
def ce_bind(builder:IdentityBuilder; source:tuple<value:auto(TT)>; next:block<(item:TT):auto(RR)>) : RR {
    return invoke(next,source.value)
}
def ce_return(builder:IdentityBuilder; value:auto(TT)) {return (value=value)}
def ce_zero(builder:IdentityBuilder) {return (value=CeUnit())}
def ce_combine(builder:IdentityBuilder; first:tuple<value:CeUnit>; next:block<():auto(RR)>) : RR {return invoke(next)}
