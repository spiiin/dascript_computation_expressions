options gen2
module list_builder public
require ./computation_builders.das public
require daslib/rtti

struct ListContext {_ce_marker:uint8}
struct MoveListContext {_ce_marker:uint8}
def ListBuilder(unused : type<auto(TT)>) {
    static_if (typeinfo can_copy(type<TT>)) {
        return (kind=ListContext(), element=default<TT -const>)
    } else {
        var marker:TT -const -&?
        return (kind=MoveListContext(), element=marker)
    }
}

def ListBuilder() => ListBuilder(type<int>)
def ce_zero(builder : tuple<kind : ListContext; element : auto(TT)>) : array<TT> {
    var inscope values : array<TT>
    return <- values
}
def ce_return(builder : tuple<kind : ListContext; element : auto(TT)>; value : TT) : array<TT> {
    var inscope values : array<TT>
    values |> push(value)
    return <- values
}
def ce_unwrap(builder : tuple<kind : ListContext; element : auto(TT)>; source : auto(UU)[]) : UU =>
    source[0]
def ce_unwrap(builder : tuple<kind : ListContext; element : auto(TT)>; source : array<auto(UU)>) : UU =>
    source[0]
def ce_bind(builder : tuple<kind : ListContext; element : auto(TT)>; source : auto(UU)[];
            next : block<(item : UU) : array<TT>>) : array<TT> {
    var inscope values : array<TT>
    // Walked by index, so the source is not locked while a continuation runs.
    for (sourceIndex in range(length(source))) {
        let item = source[sourceIndex]
        var inscope part <- invoke(next, item)
        for (value in part) { values |> push(value) }
    }
    return <- values
}
def ce_bind(builder : tuple<kind : ListContext; element : auto(TT)>; source : array<auto(UU)>;
            next : block<(item : UU) : array<TT>>) : array<TT> {
    var inscope values : array<TT>
    // Walked by index, so the source is not locked while a continuation runs.
    for (sourceIndex in range(length(source))) {
        let item = source[sourceIndex]
        var inscope part <- invoke(next, item)
        for (value in part) { values |> push(value) }
    }
    return <- values
}
def ce_return_from(builder : tuple<kind : ListContext; element : auto(TT)>; source : TT[]) : array<TT> {
    var inscope values : array<TT>
    for (value in source) { values |> push(value) }
    return <- values
}
def ce_return_from(builder : tuple<kind : ListContext; element : auto(TT)>; source : array<TT>) : array<TT> {
    var inscope values : array<TT>
    for (value in source) { values |> push(value) }
    return <- values
}
def ce_delay(builder : tuple<kind : ListContext; element : auto(TT)>; body : block<() : array<TT>>) : array<TT> =>
    <- invoke(body)
def ce_combine(builder : tuple<kind : ListContext; element : auto(TT)>; first : array<TT>;
               next : block<() : array<TT>>) : array<TT> {
    var inscope values : array<TT>
    for (value in first) { values |> push(value) }
    var inscope rest <- invoke(next)
    for (value in rest) { values |> push(value) }
    return <- values
}
def ce_list_append(var accumulated : array<auto(TT)>; step : array<TT>) {
    for (value in step) { accumulated |> push(value) }
}
def ce_try_finally(builder : tuple<kind : ListContext; element : auto(TT)>;
                   body : block<() : array<TT>>; cleanup : block<() : void>) : array<TT> {
    var inscope values : array<TT>
    values <- invoke(body)
    invoke(cleanup)
    return <- values
}
def ce_using(builder : tuple<kind : ListContext; element : auto(TT)>; resource : auto(UU);
             body : block<(item : UU) : array<TT>>; cleanup : block<(var item : UU) : void>) : array<TT> {
    var owned = resource
    var inscope values : array<TT>
    values <- invoke(body, owned)
    invoke(cleanup, owned)
    return <- values
}





def ce_protocol(builder : tuple<kind:ListContext;element:auto(TT)>) => CeCollectProtocol()
def ce_collect_append(builder : tuple<kind:ListContext;element:auto(TT)>;
                      var accumulated : array<TT>; step : array<TT>) { ce_list_append(accumulated, step) }

def ce_list_merge_sources(left, right : auto) {
    var inscope values : array<typedecl(ce_source_pair(left[0], right[0]))>
    for (a in left) {
        for (b in right) { values |> push(ce_source_pair(a,b)) }
    }
    return <- values
}
def ce_merge_sources(builder : tuple<kind:ListContext;element:auto(TT)>; left : auto(AA)[]; right : auto(BB)[]) =>
    <- ce_list_merge_sources(left, right)
def ce_merge_sources(builder : tuple<kind:ListContext;element:auto(TT)>; left : array<auto(AA)>; right : auto(BB)[]) =>
    <- ce_list_merge_sources(left, right)
def ce_merge_sources(builder : tuple<kind:ListContext;element:auto(TT)>; left : auto(AA)[]; right : array<auto(BB)>) =>
    <- ce_list_merge_sources(left, right)
def ce_merge_sources(builder : tuple<kind:ListContext;element:auto(TT)>; left : array<auto(AA)>; right : array<auto(BB)>) =>
    <- ce_list_merge_sources(left, right)


// One output array; no singleton arrays from ce_return for individual items.
def ce_list_map(source : auto; mapper : block<(value:auto(UU)):auto(TT)>) : array<TT -const -&> {
    var inscope values : array<TT -const -&>
    for (index in range(length(source))) { values |> push(invoke(mapper, source[index])) }
    return <- values
}
def ce_bind_return(builder : tuple<kind:ListContext;element:auto(TT)>; source : array<auto(UU)>;
                   mapper : block<(value:UU):TT>) : array<TT> => <- ce_list_map(source, mapper)
def ce_bind_return(builder : tuple<kind:ListContext;element:auto(TT)>; source : auto(UU)[];
                   mapper : block<(value:UU):TT>) : array<TT> => <- ce_list_map(source, mapper)

// Snapshot each input before mapping, preserving materialized-product semantics
// even when the mapper changes a borrowed input. No array of N*M pairs.
def ce_list_map2(left,right:auto; mapper:block<(pair:tuple<first:auto(AA);second:auto(BB)>):auto(TT)>) : array<TT -const -&> {
    var inscope values:array<TT -const -&>
    if (length(left)==0 || length(right)==0) { return <- values }
    var inscope leftSnapshot:array<AA -const -&>
    var inscope rightSnapshot:array<BB -const -&>
    for (i in range(length(left))) { leftSnapshot |> push(left[i]) }
    for (j in range(length(right))) { rightSnapshot |> push(right[j]) }
    for (i in range(length(leftSnapshot))) {
        for (j in range(length(rightSnapshot))) {
            values |> push(invoke(mapper,ce_source_pair(leftSnapshot[i],rightSnapshot[j])))
        }
    }
    return <- values
}

def ce_bind2_return(builder:tuple<kind:ListContext;element:auto(TT)>; left:auto(AA)[]; right:auto(BB)[];
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):TT>) : array<TT> =>
                        <- ce_list_map2(left,right,mapper)

def ce_bind2_return(builder:tuple<kind:ListContext;element:auto(TT)>; left:auto(AA)[]; right:array<auto(BB)>;
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):TT>) : array<TT> =>
                        <- ce_list_map2(left,right,mapper)

def ce_bind2_return(builder:tuple<kind:ListContext;element:auto(TT)>; left:array<auto(AA)>; right:auto(BB)[];
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):TT>) : array<TT> =>
                        <- ce_list_map2(left,right,mapper)

def ce_bind2_return(builder:tuple<kind:ListContext;element:auto(TT)>; left:array<auto(AA)>; right:array<auto(BB)>;
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):TT>) : array<TT> =>
                        <- ce_list_map2(left,right,mapper)

// Snapshot the grouped sources, then flatten each continuation result.
def ce_list_bind2(left,right:auto; mapper:block<(pair:tuple<first:auto(AA);second:auto(BB)>):array<auto(TT)>>) : array<TT> {
    var inscope values, part:array<TT>
    if (length(left)==0 || length(right)==0) { return <- values }
    var inscope leftSnapshot:array<AA -const -&>
    var inscope rightSnapshot:array<BB -const -&>
    for (i in range(length(left))) { leftSnapshot |> push(left[i]) }
    for (j in range(length(right))) { rightSnapshot |> push(right[j]) }
    for (i in range(length(leftSnapshot))) {
        for (j in range(length(rightSnapshot))) {
            part <- invoke(mapper,ce_source_pair(leftSnapshot[i],rightSnapshot[j]))
            for (k in range(length(part))) { values |> push(part[k]) }
            delete part
        }
    }
    return <- values
}

def ce_bind2(builder:tuple<kind:ListContext;element:auto(TT)>; left:auto(AA)[]; right:auto(BB)[];
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):array<TT>>) : array<TT> =>
                        <- ce_list_bind2(left,right,mapper)

def ce_bind2(builder:tuple<kind:ListContext;element:auto(TT)>; left:auto(AA)[]; right:array<auto(BB)>;
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):array<TT>>) : array<TT> =>
                        <- ce_list_bind2(left,right,mapper)

def ce_bind2(builder:tuple<kind:ListContext;element:auto(TT)>; left:array<auto(AA)>; right:auto(BB)[];
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):array<TT>>) : array<TT> =>
                        <- ce_list_bind2(left,right,mapper)

def ce_bind2(builder:tuple<kind:ListContext;element:auto(TT)>; left:array<auto(AA)>; right:array<auto(BB)>;
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):array<TT>>) : array<TT> =>
                        <- ce_list_bind2(left,right,mapper)

// Move-only output: each bind owns its input; callbacks borrow individual items.
def ce_protocol(builder:tuple<kind:MoveListContext;element:auto(TT)?>) => CeOwnedProtocol()
def ce_zero(builder:tuple<kind:MoveListContext;element:auto(TT)?>) : array<TT> {
    var inscope values:array<TT>
    return <- values
}
def ce_return_move(builder:tuple<kind:MoveListContext;element:auto(TT)?>; var value:TT) : array<TT> {
    var inscope values:array<TT>
    values |> emplace <| value
    return <- values
}
def ce_return(builder:tuple<kind:MoveListContext;element:auto(TT)?>; value:TT) : array<TT> {
    concept_assert(false,"move-only List: use return <- or yield <-")
    return <- ce_zero(builder)
}
def ce_unwrap(builder:tuple<kind:MoveListContext;element:auto(TT)?>; var source:array<auto(UU)>) : UU& {unsafe {return source[0]}}
def ce_unwrap(builder:tuple<kind:MoveListContext;element:auto(TT)?>; var source:auto(UU)[]) : UU& {unsafe {return source[0]}}
def ce_move_list_append(var values:array<auto(TT)>; var part:array<TT>) {
    for (i in range(length(part))) {values |> emplace <| part[i]}
}
def ce_bind(builder:tuple<kind:MoveListContext;element:auto(TT)?>; var source:array<auto(SS)>;
            next:block<(var item:auto(UU)):auto(RR)>) : RR {
    var inscope owner <- source
    var inscope values, part:array<TT>
    for(i in range(length(owner))) {
        part <- invoke(next,owner[i])
        ce_move_list_append(values,part)
        delete part
    }
    return <- values
}
def ce_return_from(builder:tuple<kind:MoveListContext;element:auto(TT)?>; var source:array<TT>) =>
    <- source
def ce_delay(builder:tuple<kind:MoveListContext;element:auto(TT)?>; body:block<():array<TT>>) =>
    <- invoke(body)
def ce_combine(builder:tuple<kind:MoveListContext;element:auto(TT)?>; var first:array<TT>;
               next:block<():array<TT>>) : array<TT> {
    var inscope values <- first
    var inscope rest:array<TT>
    rest <- invoke(next);ce_move_list_append(values,rest)
    return <- values
}
def ce_collect_append(builder:tuple<kind:MoveListContext;element:auto(TT)?>; var values,step:array<TT>) {ce_move_list_append(values,step)}
def ce_loop_failed(builder:tuple<kind:MoveListContext;element:auto(TT)?>; values:array<TT>) => false
def ce_merge_sources(builder:tuple<kind:MoveListContext;element:auto(TT)?>; left,right:auto) {
    concept_assert(typeinfo can_copy(left[0]) && typeinfo can_copy(right[0]),"move-only List: and_bind Cartesian product requires copyable input elements")
    return <- ce_list_merge_sources(left,right)
}

def ce_try_finally(builder : tuple<kind : MoveListContext; element : auto(TT)?>;
                   body : block<() : array<TT>>; cleanup : block<() : void>) : array<TT> {
    var inscope values : array<TT>
    values <- invoke(body)
    invoke(cleanup)
    return <- values
}

def ce_using(builder : tuple<kind : MoveListContext; element : auto(TT)?>; resource : auto(UU);
             body : block<(item : UU) : array<TT>>; cleanup : block<(var item : UU) : void>) : array<TT> {
    var owned = resource
    var inscope values : array<TT>
    values <- invoke(body, owned)
    invoke(cleanup, owned)
    return <- values
}


// Opt-in consuming input with `var item & = source |> bind`, including maps
// from owning items to ordinary copyable values.
def ce_unwrap_borrow(builder:tuple<kind:ListContext;element:auto(TT)>; var source:array<auto(UU)>) : UU& {unsafe {return source[0]}}
def ce_bind(builder:tuple<kind:ListContext;element:auto(TT)>; var source:array<auto(SS)>;
            next:block<(var item:auto(UU)):auto(RR)>) : RR {
    var inscope owner <- source
    var inscope values, part:array<TT>
    for(i in range(length(owner))) {
        part <- invoke(next,owner[i])
        ce_move_list_append(values,part)
        delete part
    }
    return <- values
}

def ce_return_move(builder:tuple<kind:ListContext;element:auto(TT)>; var value:TT) : array<TT> {
    var inscope values:array<TT>
    values |> emplace(value)
    return <- values
}
def ce_unwrap_borrow(builder:tuple<kind:ListContext;element:auto(TT)>; var source:auto(UU)[]) : UU& {unsafe {return source[0]}}

def ce_bind(builder:tuple<kind:ListContext;element:auto(TT)>; var source:auto(SS)[];
            next:block<(var item:auto(UU)):auto(RR)>) : RR {
    var inscope owner:array<SS>
    for(i in range(length(source))) {owner |> emplace(source[i])}
    return <- ce_bind(builder,owner,next)
    return <- default<RR>
}

def ce_bind(builder:tuple<kind:MoveListContext;element:auto(TT)?>; var source:auto(SS)[];
            next:block<(var item:auto(UU)):auto(RR)>) : RR {
    var inscope owner:array<SS>
    for(i in range(length(source))) {owner |> emplace(source[i])}
    return <- ce_bind(builder,owner,next)
    return <- default<RR>
}

def ce_return_from(builder:tuple<kind:MoveListContext;element:auto(TT)?>; var source:TT[]) : array<TT> {
    var inscope values:array<TT>
    for(i in range(length(source))) {values |> emplace(source[i])}
    return <- values
}

// A single output buffer for linear copyable bind chains or a consuming map.
def ce_collect_sink(builder:tuple<kind:ListContext;element:auto(TT)>) =>
    ce_collect_sink_protocol(type<TT>)
def ce_collect_sink(builder:tuple<kind:MoveListContext;element:auto(TT)?>) =>
    ce_collect_sink_protocol(type<TT>)

def ce_collect_into(builder:auto; body:block<(var output:array<auto(TT)>):CeUnit>) : array<TT> {
    var inscope output:array<TT>
    invoke(body,output)
    return <- output
}
def ce_collect_emit(builder:tuple<kind:ListContext;element:auto(TT)>; var output:array<TT>; value:TT) {
    output |> push(value)
}
def ce_collect_emit_move(builder:tuple<kind:MoveListContext;element:auto(TT)?>; var output:array<TT>; var value:TT) {
    output |> emplace(value)
}
def private ce_list_visit_copy(source:auto; body:auto) : CeUnit {
    for(i in range(length(source))) {
        let snapshot=source[i]
        invoke(body,snapshot)
    }
    return CeUnit()
}
def ce_collect_each(builder:tuple<kind:ListContext;element:auto(TT)>; var output:array<TT>;
                    source:auto(UU)[]; body:block<(item:UU):CeUnit>) : CeUnit =>
                        ce_list_visit_copy(source,body)
def ce_collect_each(builder:tuple<kind:ListContext;element:auto(TT)>; var output:array<TT>;
                    source:array<auto(UU)>; body:block<(item:UU):CeUnit>) : CeUnit =>
                        ce_list_visit_copy(source,body)
// This path is restricted to one consuming bind by the macro. On panic, output
// is destroyed before remaining input, matching the original owning ce_bind.
def private ce_list_visit_owned(var output:array<auto(TT)>; var source:array<auto(SS)>; body:auto) : CeUnit {
    var inscope owner <- source
    for(i in range(length(owner))) {invoke(body,owner[i])}
    return CeUnit()
}
def ce_collect_each_move(builder:tuple<kind:ListContext;element:auto(TT)>; var output:array<TT>;
                    var source:array<auto(SS)>; body:block<(var item:auto(UU)):CeUnit>) : CeUnit =>
                        ce_list_visit_owned(output,source,body)
def ce_collect_each_move(builder:tuple<kind:MoveListContext;element:auto(TT)?>; var output:array<TT>;
                    var source:array<auto(SS)>; body:block<(var item:auto(UU)):CeUnit>) : CeUnit =>
                        ce_list_visit_owned(output,source,body)
def ce_collect_each_move(builder:tuple<kind:ListContext;element:auto(TT)>; var output:array<TT>;
                    var source:auto(SS)[]; body:block<(var item:auto(UU)):CeUnit>) : CeUnit {
    var inscope owner:array<SS>
    for(i in range(length(source))) {owner |> emplace(source[i])}
    return ce_list_visit_owned(output,owner,body)
    return CeUnit()
}
def ce_collect_each_move(builder:tuple<kind:MoveListContext;element:auto(TT)?>; var output:array<TT>;
                    var source:auto(SS)[]; body:block<(var item:auto(UU)):CeUnit>) : CeUnit {
    var inscope owner:array<SS>
    for(i in range(length(source))) {owner |> emplace(source[i])}
    return ce_list_visit_owned(output,owner,body)
    return CeUnit()
}
