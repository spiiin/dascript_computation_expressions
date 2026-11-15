options gen2
module search_builder public
require ./sequence_builder.das public
require daslib/rtti
struct SearchContext {_ce_marker:uint8}
def SearchBuilder(unused:type<auto(TT)>) {
    static_assert(typeinfo can_copy(type<TT>),"SearchBuilder requires copyable solutions")
    return (kind=SearchContext(),element=default<TT -const>)
}
def SearchBuilder() => SearchBuilder(type<int>)
def ce_protocol(builder:tuple<kind:SearchContext;element:auto(TT)>) => ce_sequence_protocol(type<TT>)
def ce_sequence_run(builder:tuple<kind:SearchContext;element:auto(TT)>; var source:iterator<TT>) =>
    <- ce_sequence_protect(source)
// Empty source prunes only this branch of the depth-first search.
def search_guard(accept:bool) {
    return <- generator<CeUnit> capture(copy(accept)) {
        if(accept) {yield CeUnit()}
        return false
    }
}
// Explicit scoped cut: keep the first solution of this source, close its rest.
// Deliberately not a global Prolog cut: surrounding choices still backtrack.
def search_once(var source:iterator<auto(TT)>) : iterator<TT> {
    return <- generator<TT> capture(<-source) {
        var value:TT
        var more=false
        more=ce_sequence_next_value(source,value)
        sequence_close(source)
        if(more) {yield value}
        return false
    } finally {ce_sequence_finalize($ {sequence_close(source)})}
}
def search_cut(var source:iterator<auto(TT)>) => <- search_once(source)

// Explicit consuming source for dynamic arrays, including temporary literals.
def search_choose(var values:array<auto(TT)>) : iterator<TT> {
    static_assert(typeinfo can_copy(type<TT>),"SearchBuilder requires copyable choices")
    return <- generator<TT> capture(<-values) {
        for(i in range(length(values))) {yield values[i]}
        return false
    } finally {delete values}
}

// Own the source; close it before publishing the last permitted solution.
// Nonpositive limits are empty and never step the source.
def search_take(var source:iterator<auto(TT)>; limit:int) : iterator<TT> {
    return <- generator<TT> capture(<-source,copy(limit)) {
        var remaining=limit
        while(remaining>0) {
            var value:TT
            var more=false
            more=ce_sequence_next_value(source,value)
            if(!more) {break}
            remaining--
            if(remaining==0) {sequence_close(source)}
            yield value
        }
        sequence_close(source)
        return false
    } finally {ce_sequence_finalize($ {sequence_close(source)})}
}

def ce_search_close_pair(var left:iterator<auto(TT)>;var right:iterator<TT>) {
    sequence_close(left)
    sequence_close(right)
}

// Ordered alternatives: exhaust left, then right. Duplicates are retained.
// Both iterator handles are owned immediately, but their bodies remain lazy.
def search_append(var left:iterator<auto(TT)>;var right:iterator<TT>) : iterator<TT> {
    return <- generator<TT> capture(<-left,<-right) {
        for(side in range(2)) {
            while(true) {
                var value:TT
                var more=false
                if(side==0) {more=ce_sequence_next_value(left,value)}
                else {more=ce_sequence_next_value(right,value)}
                if(!more) {break}
                yield value
            }
            if(side==0) {sequence_close(left)}
        }
        ce_search_close_pair(left,right)
        return false
    } finally {ce_sequence_finalize($ {ce_search_close_pair(left,right)})}
}
