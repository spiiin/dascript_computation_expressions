options gen2
module search_builder public
require ./sequence_builder.das public
require daslib/rtti

//! ``SearchBuilder(type<T>)``: lazy depth-first search with backtracking. A ``bind`` of an iterator or an
//! array tries the rest of the scope for each of its elements, ``search_guard`` abandons a branch, and
//! ``yield`` reports a solution. Require it in addition to ``computation``. Solutions are copied.

//! Marker of the builder that ``SearchBuilder(type<T>)`` returns.
struct SearchContext {_ce_marker:uint8}
//! Builder of a depth-first search that yields solutions of a copyable type ``T``; any other ``T`` is a
//! compile error. The result is a lazy ``iterator<T>``: each request resumes the search up to the next
//! ``yield``. The caller owns it and closes it with ``sequence_each``, ``sequence_close`` or a ``var inscope`` owner.
def SearchBuilder(unused:type<auto(TT)>) {
    static_assert(typeinfo can_copy(type<TT>),"SearchBuilder requires copyable solutions")
    return (kind=SearchContext(),element=default<TT -const>)
}
def ce_protocol(builder:tuple<kind:SearchContext;element:auto(TT)>) => ce_sequence_protocol(type<TT>)
def ce_sequence_run(builder:tuple<kind:SearchContext;element:auto(TT)>; var source:iterator<TT>) =>
    <- ce_sequence_protect(source)
//! A source for ``search_guard(condition) |> bind``: when ``accept`` is false, this branch of the search
//! is abandoned and the search goes on with the next element of the previous choice.
def search_guard(accept:bool) {
    return <- generator<CeUnit> capture(copy(accept)) {
        if(accept) {yield CeUnit()}
        return false
    }
}
//! Keeps the first solution of ``source`` and closes ``source`` before yielding it, which releases the
//! resources of the search behind it. Takes ownership of ``source``; nothing runs until the result is
//! stepped. The cut is scoped, unlike Prolog's: the choices around it still backtrack.
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
//! Another name for ``search_once``.
def search_cut(var source:iterator<auto(TT)>) => <- search_once(source)

//! A source that offers the elements of ``values`` in order. It takes the array: pass a temporary, such
//! as a literal, or a variable, which is left empty. The elements must be copyable.
def search_choose(var values:array<auto(TT)>) : iterator<TT> {
    static_assert(typeinfo can_copy(type<TT>),"SearchBuilder requires copyable choices")
    return <- generator<TT> capture(<-values) {
        for(i in range(length(values))) {yield values[i]}
        return false
    } finally {delete values}
}

//! At most ``limit`` solutions of ``source``. Takes ownership of ``source`` and closes it before yielding
//! the last permitted solution, or when the result is closed. A limit of zero or less yields nothing and
//! never steps ``source``.
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

//! The solutions of ``left`` followed by the solutions of ``right``; duplicates are kept. Takes ownership
//! of both iterators at once but steps ``right`` only after ``left`` is exhausted. Closing the result
//! closes both.
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
