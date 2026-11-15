options gen2
module protocol_collect_fixture public
require ../packages/computation/builder_protocol.das public
require daslib/rtti

struct ExternalCollectionContext {}
def ExternalCollectionBuilder(unused : type<auto(T)>) : tuple<kind : ExternalCollectionContext; element : T -const> {
    return (kind=ExternalCollectionContext(), element=default<T -const>)
}
def ExternalCollectionBuilder() { return ExternalCollectionBuilder(type<int>) }
def ce_zero(builder : tuple<kind : ExternalCollectionContext; element : auto(T)>) : array<T> {
    var inscope values : array<T>
    return <- values
}
def ce_return(builder : tuple<kind : ExternalCollectionContext; element : auto(T)>; value : T) : array<T> {
    var inscope values : array<T>
    values |> push(value)
    return <- values
}
def ce_unwrap(builder : tuple<kind : ExternalCollectionContext; element : auto(T)>; source : auto(U)[]) : U { return source[0] }
def ce_unwrap(builder : tuple<kind : ExternalCollectionContext; element : auto(T)>; source : array<auto(U)>) : U { return source[0] }
def ce_bind(builder : tuple<kind : ExternalCollectionContext; element : auto(T)>; source : auto(U)[];
            next : block<(item : U) : array<T>>) : array<T> {
    var inscope values : array<T>
    for (item in source) {
        var inscope part <- invoke(next, item)
        for (value in part) { values |> push(value) }
    }
    return <- values
}
def ce_bind(builder : tuple<kind : ExternalCollectionContext; element : auto(T)>; source : array<auto(U)>;
            next : block<(item : U) : array<T>>) : array<T> {
    var inscope values : array<T>
    for (item in source) {
        var inscope part <- invoke(next, item)
        for (value in part) { values |> push(value) }
    }
    return <- values
}
def ce_return_from(builder : tuple<kind : ExternalCollectionContext; element : auto(T)>; source : T[]) : array<T> {
    var inscope values : array<T>
    for (value in source) { values |> push(value) }
    return <- values
}
def ce_return_from(builder : tuple<kind : ExternalCollectionContext; element : auto(T)>; source : array<T>) : array<T> {
    var inscope values : array<T>
    for (value in source) { values |> push(value) }
    return <- values
}
def ce_delay(builder : tuple<kind : ExternalCollectionContext; element : auto(T)>; body : block<() : array<T>>) : array<T> {
    return <- invoke(body)
}
def ce_combine(builder : tuple<kind : ExternalCollectionContext; element : auto(T)>; first : array<T>;
               next : block<() : array<T>>) : array<T> {
    var inscope values : array<T>
    for (value in first) { values |> push(value) }
    var inscope rest <- invoke(next)
    for (value in rest) { values |> push(value) }
    return <- values
}
def fixture_append(var accumulated : array<auto(T)>; step : array<T>) {
    for (value in step) { accumulated |> push(value) }
}
def ce_try_finally(builder : tuple<kind : ExternalCollectionContext; element : auto(T)>;
                   body : block<() : array<T>>; cleanup : block<() : void>) : array<T> {
    var inscope values : array<T>
    values <- invoke(body)
    invoke(cleanup)
    return <- values
}
def ce_using(builder : tuple<kind : ExternalCollectionContext; element : auto(T)>; resource : auto(U);
             body : block<(item : U) : array<T>>; cleanup : block<(var item : U) : void>) : array<T> {
    var owned = resource
    var inscope values : array<T>
    values <- invoke(body, owned)
    invoke(cleanup, owned)
    return <- values
}





def ce_protocol(builder : tuple<kind:ExternalCollectionContext;element:auto(T)>) { return CeCollectProtocol() }
def ce_collect_append(builder : tuple<kind:ExternalCollectionContext;element:auto(T)>;
                      var accumulated : array<T>; step : array<T>) { fixture_append(accumulated, step) }

