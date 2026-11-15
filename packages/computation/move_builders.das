options gen2
module move_builders public
require ./computation_builders.das public
// Consuming outcomes: bind owns the variant, continuation only borrows payload.
struct MoveResultBuilder {_ce_marker:uint8}
struct MoveOptionBuilder {_ce_marker:uint8}

def move_ok(var value:auto(TT)) : Result<TT -const -&;string> {
    // SDK 0.6.5-RC2 AOT does not clear a tuple payload's source when it is
    // moved directly in a variant initializer. Enter ok with an empty payload,
    // then use a separate field move, preserving the standard Result layout.
    var vacant=default<TT -const -&>
    var result <- result::move_ok(vacant,type<string>)
    result as ok <- value
    return <- result
}
// The same for a Result that fails with E.
def ce_move_ok(var value:auto(TT); unused:type<auto(EE)>) : Result<TT -const -&;EE -const -&> {
    var vacant=default<TT -const -&>
    var result <- result::move_ok(vacant,type<EE -const -&>)
    result as ok <- value
    return <- result
}
def move_error(message:string; unused:type<auto(TT)>) : Result<TT -const -&;string> =>
    <- variant type<Result<TT -const -&;string>>(err=message)
def ce_protocol(_builder:MoveResultBuilder) => CeOwnedProtocol()
def ce_unwrap(builder:MoveResultBuilder; var source:Result<auto(TT);string>) : TT& {unsafe {return source as ok}}
def ce_return(builder:MoveResultBuilder; value:auto(TT)) : Result<TT -const -&;string> {
    concept_assert(typeinfo can_copy(type<TT>),"owned CE: use return <- value for a move-only payload")
    return <- variant type<Result<TT -const -&;string>>(ok=value)
}
def ce_return_move(builder:MoveResultBuilder; var value:auto(TT)) : Result<TT;string> =>
    <- move_ok(value)
def ce_return_from(builder:MoveResultBuilder; var source:Result<auto(TT);string>) => <- source
def ce_delay(builder:MoveResultBuilder; body:block<():auto(RR)>) : RR => <- invoke(body)
def ce_zero(_builder:MoveResultBuilder) : Result<CeUnit;string> =>
    <- variant type<Result<CeUnit;string>>(ok=CeUnit())
// V preserves scalar references and native reference types (array/struct).
// invoke below checks compatibility with the actual payload T.
def ce_bind(builder:MoveResultBuilder; var source:Result<auto(TT);string>;
            next:block<(var value:auto(VV)):auto(RR)>) : RR {
    var inscope owner <- source
    if (owner is err) {return <- variant type<RR>(err=owner as err)}
    var inscope result:RR
    result <- invoke(next,owner as ok)
    return <- result
}
def ce_combine(builder:MoveResultBuilder; first:Result<CeUnit;string>; next:block<():auto(RR)>) : RR {
    if (first is err) {return <- variant type<RR>(err=first as err)}
    return <- invoke(next)
}
def ce_loop_failed(builder:MoveResultBuilder; result:Result<CeUnit;string>) => result is err
def ce_collect_append(builder:MoveResultBuilder; var total:Result<CeUnit;string>;
                      step:Result<CeUnit;string>) {if (!(total is err)) {total=step}}
def ce_merge_sources(builder:MoveResultBuilder; var left:Result<auto;string>;
                     var right:Result<auto;string>) {
    var inscope a <- left
    var inscope b <- right
    unsafe {
        if(a is err) {return <- typeinfo ce_canonical(move_error(a as err,type<tuple<first:typedecl(a as ok) -const -&;second:typedecl(b as ok) -const -&>>))}
        if(b is err) {return <- typeinfo ce_canonical(move_error(b as err,type<tuple<first:typedecl(a as ok) -const -&;second:typedecl(b as ok) -const -&>>))}
        var pair <- (first <- (a as ok),second <- (b as ok))
        return <- typeinfo ce_canonical(move_ok(pair))
    }
}

def move_none(unused:type<auto(TT)>) : Option<TT -const -&> => <- default<Option<TT -const -&>>
def ce_protocol(_builder:MoveOptionBuilder) => CeOwnedProtocol()
def ce_unwrap(builder:MoveOptionBuilder; var source:Option<auto(TT)>) : TT& {unsafe {return source as some}}
def ce_return(builder:MoveOptionBuilder; value:auto(TT)) : Option<TT -const -&> {
    concept_assert(typeinfo can_copy(type<TT>),"owned CE: use return <- value for a move-only payload")
    return <- variant type<Option<TT -const -&>>(some=value)
}
def ce_return_move(builder:MoveOptionBuilder; var value:auto(TT)) : Option<TT> =>
    <- ce_move_some(value)
def ce_return_from(builder:MoveOptionBuilder; var source:Option<auto(TT)>) => <- source
def ce_delay(builder:MoveOptionBuilder; body:block<():auto(RR)>) : RR => <- invoke(body)
def ce_zero(_builder:MoveOptionBuilder) : Option<CeUnit> =>
    <- variant type<Option<CeUnit>>(some=CeUnit())
def ce_bind(builder:MoveOptionBuilder; var source:Option<auto(TT)>;
            next:block<(var value:auto(VV)):auto(RR)>) : RR {
    var inscope owner <- source
    if (owner is none) {return <- default<RR>}
    var inscope result:RR
    result <- invoke(next,owner as some)
    return <- result
}
def ce_combine(builder:MoveOptionBuilder; first:Option<CeUnit>; next:block<():auto(RR)>) : RR {
    if (first is none) {return <- default<RR>}
    return <- invoke(next)
}
def ce_loop_failed(builder:MoveOptionBuilder; result:Option<CeUnit>) => result is none
def ce_collect_append(builder:MoveOptionBuilder; var total:Option<CeUnit>;
                      step:Option<CeUnit>) {if (!(total is none)) {total=step}}
def ce_merge_sources(builder:MoveOptionBuilder; var left:Option<auto>;
                     var right:Option<auto>) {
    var inscope a <- left
    var inscope b <- right
    unsafe {
        if(a is none || b is none) {return <- typeinfo ce_canonical(default<Option<tuple<first:typedecl(a as some) -const -&;second:typedecl(b as some) -const -&>>>)}
        var pair <- (first <- (a as some),second <- (b as some))
        return <- typeinfo ce_canonical(ce_move_some(pair))
    }
}

def ce_try_finally(builder:MoveResultBuilder; body:block<():auto(RR)>; cleanup:block<():void>) : RR {
    var inscope result:RR
    result <- invoke(body)
    invoke(cleanup)
    return <- result
}
def ce_using(builder:MoveResultBuilder; resource:auto(TT); body:block<(item:TT):auto(RR)>;
             cleanup:block<(var item:TT):void>) : RR {
    concept_assert(typeinfo can_copy(type<TT>),"owned CE: move-only payloads use bind; use_resource needs a copyable handle")
    var owner=resource
    var inscope result:RR
    result <- invoke(body,owner)
    invoke(cleanup,owner)
    return <- result
}

def ce_try_finally(builder:MoveOptionBuilder; body:block<():auto(RR)>; cleanup:block<():void>) : RR {
    var inscope result:RR
    result <- invoke(body)
    invoke(cleanup)
    return <- result
}
def ce_using(builder:MoveOptionBuilder; resource:auto(TT); body:block<(item:TT):auto(RR)>;
             cleanup:block<(var item:TT):void>) : RR {
    concept_assert(typeinfo can_copy(type<TT>),"owned CE: move-only payloads use bind; use_resource needs a copyable handle")
    var owner=resource
    var inscope result:RR
    result <- invoke(body,owner)
    invoke(cleanup,owner)
    return <- result
}

