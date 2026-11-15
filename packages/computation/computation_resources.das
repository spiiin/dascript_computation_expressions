options gen2
module computation_resources public

// Cleanup runs when the body returns, however it returns: with a value, with
// an Error or None, or through an early exit. A panic is fatal and runs nothing.
def ce_try_finally(builder : auto; body : block<() : auto(RR)>; cleanup : block<() : void>) : RR {
    var result : RR
    result = invoke(body)
    invoke(cleanup)
    return result
}
// Ownership is scoped here. The macro creates cleanup in the caller's module
// so that its ce_dispose overload is visible, without a global default disposer.
def ce_using(builder : auto; resource : auto(TT); body : block<(item : TT) : auto(RR)>;
             cleanup : block<(var item : TT) : void>) : RR {
    var owned = resource
    var result : RR
    result = invoke(body, owned)
    invoke(cleanup, owned)
    return result
}



// Explicit owning use_resource: the continuation borrows the resource.
// ce_dispose owns cleanup, including any nested allocations in the resource.
def ce_using_move(builder:auto; var resource:auto(TT); body:block<(var item:auto(UU)):auto(RR)>;
                  cleanup:block<(var item:TT):void>) : RR {
    var owned <- resource
    var result:RR
    static_if (typeinfo can_copy(type<RR>)) {result=invoke(body,owned)}
    else {result <- invoke(body,owned)}
    invoke(cleanup,owned)
    static_if (typeinfo can_copy(type<RR>)) {return result}
    else {return <- result}
}

// Stable address for the body and cleanup generators; no owning value capture.
def ce_resource_cell_move(var resource:auto(TT)) => new tuple<value:TT>(value <- resource)
def ce_resource_cell_close(var cell:tuple<value:auto(TT)>?; cleanup:block<(var item:TT):void>) {
    var owned <- cell.value
    // The cell now holds a moved-from resource; its real payload has one owner.
    unsafe {delete cell}
    invoke(cleanup,owned)
}
