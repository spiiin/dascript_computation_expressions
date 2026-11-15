options gen2
module protocol_collect_fixture public
require ../packages/computation/builder_protocol.das public
require daslib/rtti

struct ExternalCollectionContext {}
def ExternalCollectionBuilder(unused : type<auto(TT)>) : tuple<kind : ExternalCollectionContext; element : TT -const> {
    return (kind=ExternalCollectionContext(), element=default<TT -const>)
}
def ExternalCollectionBuilder() { return ExternalCollectionBuilder(type<int>) }
def ce_zero(builder : tuple<kind : ExternalCollectionContext; element : auto(TT)>) : array<TT> {
    var inscope values : array<TT>
    return <- values
}
def ce_return(builder : tuple<kind : ExternalCollectionContext; element : auto(TT)>; value : TT) : array<TT> {
    var inscope values : array<TT>
    values |> push(value)
    return <- values
}
def ce_unwrap(builder : tuple<kind : ExternalCollectionContext; element : auto(TT)>; source : auto(UU)[]) : UU { return source[0] }
def ce_unwrap(builder : tuple<kind : ExternalCollectionContext; element : auto(TT)>; source : array<auto(UU)>) : UU { return source[0] }
def ce_bind(builder : tuple<kind : ExternalCollectionContext; element : auto(TT)>; source : auto(UU)[];
            next : block<(item : UU) : array<TT>>) : array<TT> {
    var inscope values : array<TT>
    for (item in source) {
        var inscope part <- invoke(next, item)
        for (value in part) { values |> push(value) }
    }
    return <- values
}
def ce_bind(builder : tuple<kind : ExternalCollectionContext; element : auto(TT)>; source : array<auto(UU)>;
            next : block<(item : UU) : array<TT>>) : array<TT> {
    var inscope values : array<TT>
    for (item in source) {
        var inscope part <- invoke(next, item)
        for (value in part) { values |> push(value) }
    }
    return <- values
}
def ce_return_from(builder : tuple<kind : ExternalCollectionContext; element : auto(TT)>; source : TT[]) : array<TT> {
    var inscope values : array<TT>
    for (value in source) { values |> push(value) }
    return <- values
}
def ce_return_from(builder : tuple<kind : ExternalCollectionContext; element : auto(TT)>; source : array<TT>) : array<TT> {
    var inscope values : array<TT>
    for (value in source) { values |> push(value) }
    return <- values
}
def ce_delay(builder : tuple<kind : ExternalCollectionContext; element : auto(TT)>; body : block<() : array<TT>>) : array<TT> {
    return <- invoke(body)
}
def ce_combine(builder : tuple<kind : ExternalCollectionContext; element : auto(TT)>; first : array<TT>;
               next : block<() : array<TT>>) : array<TT> {
    var inscope values : array<TT>
    for (value in first) { values |> push(value) }
    var inscope rest <- invoke(next)
    for (value in rest) { values |> push(value) }
    return <- values
}
def fixture_append(var accumulated : array<auto(TT)>; step : array<TT>) {
    for (value in step) { accumulated |> push(value) }
}
def ce_try_finally(builder : tuple<kind : ExternalCollectionContext; element : auto(TT)>;
                   body : block<() : array<TT>>; cleanup : block<() : void>) : array<TT> {
    var inscope values : array<TT>
    values <- invoke(body)
    invoke(cleanup)
    return <- values
}
def ce_using(builder : tuple<kind : ExternalCollectionContext; element : auto(TT)>; resource : auto(UU);
             body : block<(item : UU) : array<TT>>; cleanup : block<(var item : UU) : void>) : array<TT> {
    var owned = resource
    var inscope values : array<TT>
    values <- invoke(body, owned)
    invoke(cleanup, owned)
    return <- values
}





def ce_protocol(builder : tuple<kind:ExternalCollectionContext;element:auto(TT)>) { return CeCollectProtocol() }
def ce_collect_append(builder : tuple<kind:ExternalCollectionContext;element:auto(TT)>;
                      var accumulated : array<TT>; step : array<TT>) { fixture_append(accumulated, step) }

