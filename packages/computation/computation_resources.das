options gen2
module computation_resources public
require daslib/rtti

// Cleanup runs when the body returns, however it returns: with a value, with
// an Error or None, or through an early exit. A panic is fatal and runs nothing.
def ce_try_finally(builder : auto; body : block<() : auto(R)>; cleanup : block<() : void>) : R {
    var result : R
    result = invoke(body)
    invoke(cleanup)
    return result
}
// Ownership is scoped here. The macro creates cleanup in the caller's module
// so that its ce_dispose overload is visible, without a global default disposer.
def ce_using(builder : auto; resource : auto(T); body : block<(item : T) : auto(R)>;
             cleanup : block<(var item : T) : void>) : R {
    var owned = resource
    var result : R
    result = invoke(body, owned)
    invoke(cleanup, owned)
    return result
}



// Explicit owning use_resource: the continuation borrows the resource.
// ce_dispose owns cleanup, including any nested allocations in the resource.
def ce_using_move(builder:auto; var resource:auto(T); body:block<(var item:auto(U)):auto(R)>;
                  cleanup:block<(var item:T):void>) : R {
    var owned <- resource
    var result:R
    static_if (typeinfo can_copy(type<R>)) {result=invoke(body,owned)}
    else {result <- invoke(body,owned)}
    invoke(cleanup,owned)
    static_if (typeinfo can_copy(type<R>)) {return result}
    else {return <- result}
}

// Stable address for the body and cleanup generators; no owning value capture.
def ce_resource_cell_move(var resource:auto(T)) {
    return new tuple<value:T>(value <- resource)
}
def ce_resource_cell_close(var cell:tuple<value:auto(T)>?; cleanup:block<(var item:T):void>) {
    var owned <- cell.value
    // The cell now holds a moved-from resource; its real payload has one owner.
    unsafe {delete cell}
    invoke(cleanup,owned)
}
