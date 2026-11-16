options gen2
module query_builder public
require ../../packages/computation/list_builder.das public
require math
require daslib/rtti
struct QueryContext {_ce_marker:uint8}
def QueryBuilder(unused:type<auto(TT)>) {
    static_assert(typeinfo can_copy(type<TT>),"QueryBuilder requires copyable rows")
    return (kind=QueryContext(),element=default<TT -const>)
}
def ce_protocol(builder:tuple<kind:QueryContext;element:auto(TT)>) {return CeCollectProtocol()}
def ce_zero(builder:tuple<kind:QueryContext;element:auto(TT)>) {return <- ce_zero(ListBuilder(type<TT>))}
def ce_return(builder:tuple<kind:QueryContext;element:auto(TT)>; value:TT) {return <- ce_return(ListBuilder(type<TT>),value)}
def ce_unwrap(builder:tuple<kind:QueryContext;element:auto(TT)>; source:auto) {return ce_unwrap(ListBuilder(type<TT>),source)}
def ce_bind(builder:tuple<kind:QueryContext;element:auto(TT)>; source:array<auto(UU)>; next:block<(row:UU):array<TT>>) {
    return <- ce_bind(ListBuilder(type<TT>),source,next)
}
def ce_bind(builder:tuple<kind:QueryContext;element:auto(TT)>; source:auto(UU)[]; next:block<(row:UU):array<TT>>) {
    return <- ce_bind(ListBuilder(type<TT>),source,next)
}
def ce_return_from(builder:tuple<kind:QueryContext;element:auto(TT)>; source:auto) {return <- ce_return_from(ListBuilder(type<TT>),source)}
def ce_delay(builder:tuple<kind:QueryContext;element:auto(TT)>; body:block<():array<TT>>) {return <- invoke(body)}
def ce_combine(builder:tuple<kind:QueryContext;element:auto(TT)>; first:array<TT>; next:block<():array<TT>>) {
    return <- ce_combine(ListBuilder(type<TT>),first,next)
}
def ce_collect_append(builder:tuple<kind:QueryContext;element:auto(TT)>; var accumulated:array<TT>; step:array<TT>) {ce_list_append(accumulated,step)}
def ce_merge_sources(builder:tuple<kind:QueryContext;element:auto(TT)>; left,right:auto) {return <- ce_list_merge_sources(left,right)}
def ce_try_finally(builder:tuple<kind:QueryContext;element:auto(TT)>; body:block<():array<TT>>; cleanup:block<():void>) {
    return <- ce_try_finally(ListBuilder(type<TT>),body,cleanup)
}
def ce_using(builder:tuple<kind:QueryContext;element:auto(TT)>; resource:auto(UU); body:block<(row:UU):array<TT>>; cleanup:block<(var row:UU):void>) {
    return <- ce_using(ListBuilder(type<TT>),resource,body,cleanup)
}
// where as a CE step: skip the remaining continuation for rejected rows.
def query_where(accept:bool) {
    var inscope rows:array<CeUnit>
    if(accept) {rows |> push(CeUnit())}
    return <- rows
}
// Collection operators are ordinary pipes, also usable outside CE.
def query_where(source:auto; predicate:block<(row:auto(TT)):bool>) {
    var inscope rows:array<TT -const -&>
    for(i in range(length(source))) {if(invoke(predicate,source[i])) {rows |> push(source[i])}}
    return <- rows
}
def query_select(source:auto; project:block<(row:auto(TT)):auto(UU)>) {
    var inscope rows:array<UU -const -&>
    for(i in range(length(source))) {rows |> push(invoke(project,source[i]))}
    return <- rows
}
// Stable inner equijoin: outer left order, then right order; duplicates retained.
def query_join(left,right:auto; leftKey:block<(row:auto(LL)):auto(KK)>; rightKey:block<(row:auto(RR)):KK>) {
    var inscope rows:array<tuple<first:LL -const -&;second:RR -const -&>>
    for(i in range(length(left))) {
        let key=invoke(leftKey,left[i])
        for(j in range(length(right))) {
            if(key==invoke(rightKey,right[j])) {rows |> push(ce_source_pair(left[i],right[j]))}
        }
    }
    return <- rows
}

// Stable ascending order (descending=true reverses key order, not ties).
// Keys are evaluated exactly once per row, in source order.
def query_order_by(source:auto; key:block<(row:auto(TT)):auto(KK)>; descending:bool=false) {
    static_assert(typeinfo can_copy(type<TT>),"query_order_by requires copyable rows")
    static_assert(typeinfo can_copy(type<KK>),"query_order_by requires copyable keys")
    var inscope keys:array<KK -const -&>
    var inscope order:array<int>
    var inscope scratch:array<int>
    var inscope rows:array<TT -const -&>
    let count=length(source)
    for(i in range(count)) {keys |> push(invoke(key,source[i]));order |> push(i)}
    scratch.resize(count)
    var width=1
    while(width<count) {
        var start=0
        while(start<count) {
            let middle=start+min(width,count-start)
            let end=middle+min(width,count-middle)
            var left=start
            var right=middle
            for(outIndex in range(start,end)) {
                var useRight=false
                if(right<end) {
                    if(left>=middle) {useRight=true}
                    elif(descending) {useRight=keys[order[left]]<keys[order[right]]}
                    else {useRight=keys[order[right]]<keys[order[left]]}
                }
                if(useRight) {scratch[outIndex]=order[right];right++}
                else {scratch[outIndex]=order[left];left++}
            }
            start=end
        }
        for(i in range(count)) {order[i]=scratch[i]}
        if(width>=count-width) {break}
        width*=2
    }
    for(i in range(count)) {rows |> push(source[order[i]])}
    return <- rows
}

// Stable groups: first appearance of key, then source order inside each group.
// Equality-based lookup deliberately needs no hash function on user keys.
def query_group_by(source:auto; key:block<(row:auto(TT)):auto(KK)>) {
    static_assert(typeinfo can_copy(type<TT>),"query_group_by requires copyable rows")
    static_assert(typeinfo can_copy(type<KK>),"query_group_by requires copyable keys")
    var inscope groups:array<tuple<key:KK -const -&;values:array<TT -const -&>>>
    for(i in range(length(source))) {
        let rowKey=invoke(key,source[i])
        var found=-1
        for(j in range(length(groups))) {
            if(groups[j].key==rowKey) {found=j;break}
        }
        if(found<0) {
            var inscope group:tuple<key:KK -const -&;values:array<TT -const -&>>
            group.key=rowKey
            groups |> emplace(group)
            found=length(groups)-1
        }
        groups[found].values |> push(source[i])
    }
    return <- groups
}

// Keep the first row for each key. Keys are evaluated once per input row.
def query_distinct(source:auto; key:block<(row:auto(TT)):auto(KK)>) {
    static_assert(typeinfo can_copy(type<TT>),"query_distinct requires copyable rows")
    static_assert(typeinfo can_copy(type<KK>),"query_distinct requires copyable keys")
    var inscope keys:array<KK -const -&>
    var inscope rows:array<TT -const -&>
    for(i in range(length(source))) {
        let rowKey=invoke(key,source[i])
        var found=false
        for(j in range(length(keys))) {if(keys[j]==rowKey) {found=true;break}}
        if(!found) {keys |> push(rowKey);rows |> push(source[i])}
    }
    return <- rows
}

def query_distinct(source:auto) {
    return <- query_distinct(source,$(row:typedecl(source[0]) -const -&) {return row})
}

// Groups contain owning arrays; bind them explicitly by mutable reference.
def ce_unwrap_borrow(builder:tuple<kind:QueryContext;element:auto(TT)>; var source:array<auto(UU)>) : UU& {
    unsafe {return source[0]}
}
def ce_bind(builder:tuple<kind:QueryContext;element:auto(TT)>; var source:array<auto(SS)>;
            next:block<(var row:auto(UU)):auto(RR)>) : RR {
    return <- ce_bind(ListBuilder(type<TT>),source,next)
}

// Block-last overload for source |> query_order_by(true) <| key.
def query_order_by(source:auto; descending:bool; key:block<(row:auto(TT)):auto(KK)>) {
    return <- query_order_by(source,key,descending)
}
