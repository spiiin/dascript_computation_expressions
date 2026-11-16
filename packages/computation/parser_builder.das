options gen2
module parser_builder public
require ./builder_protocol.das public
require daslib/strings_convert
require daslib/strings_boost

//! A text parser written as a computation expression: ``computation(ParserBuilder(text=...)) { ... }``
//! reads the text one operation at a time (``parser_literal("x") |> bind``) and stops at the first
//! failure. The outcome is a variant: ``parsed`` with the value, the position after it and a commit
//! flag, or ``failure`` with a ``ParseDiagnostic``. Require it for small hand-written grammars
//! with choice, repetition, backtracking and cut.

//! Where and why a parse failed: ``position`` is the byte offset, ``line`` and ``column`` its
//! 1-based coordinates, ``expected`` what the parser wanted there. ``committed``: the failure came
//! after a ``parser_commit``, so alternatives are not tried. ``rewound``, ``rewind_position``: a
//! ``parser_attempt`` backed out to that position. ``consumed``: input was read before failing.
//! ``fatal``: a repeated parser matched without advancing; no combinator recovers from it.
struct ParseDiagnostic {
    position:int
    line:int
    column:int
    expected:string
    committed:bool
    rewound:bool
    rewind_position:int
    consumed:bool
    fatal:bool
}
//! Builder and cursor of a parse: the ``text`` being read, the current byte ``position`` and whether
//! this computation has committed. Start with ``ParserBuilder(text=source)``. A subgrammar called
//! through ``parser_call`` receives a copy of the cursor and passes it to its own
//! ``computation(cursor) { ... }``, which then reads from that position.
struct ParserBuilder {
    text:string
    position:int
    committed:bool
}
//! The operation ``parser_literal`` returns: match ``text`` exactly.
struct ParserLiteral {text:string}
//! The operation ``parser_int`` returns.
struct ParserInteger {_ce_marker:uint8}
//! The operation ``parser_eof`` returns.
struct ParserEnd {_ce_marker:uint8}
//! The operation ``parser_spaces`` returns.
struct ParserSpaces {_ce_marker:uint8}
//! Marks the operation tuple that ``parser_choice`` returns.
struct parserAlternativesTag {_ce_marker:uint8}
//! Marks the operation tuple that ``parser_commit(source)`` returns.
struct parserCutTag {_ce_marker:uint8}
//! Marks the operation tuple that ``parser_attempt`` returns.
struct parserAttemptTag {_ce_marker:uint8}
//! Marks the operation tuple that ``parser_optional`` returns.
struct parserOptionalTag {_ce_marker:uint8}
//! Marks the operation tuple that ``parser_many`` and ``parser_many1`` return.
struct parserRepeatTag {_ce_marker:uint8}
//! Marks the operation tuple that ``parser_sep_by`` returns.
struct parserSeparatedTag {_ce_marker:uint8}

//! Operation that matches ``text`` exactly at the current position and yields it as a ``string``.
//! On a mismatch the failure points at the first byte that differs.
def parser_literal(text:string) => ParserLiteral(text=text)
//! Operation that reads a decimal ``int`` with an optional leading ``-``. It fails expecting
//! ``integer`` when there are no digits and ``32-bit integer`` when the number does not fit.
def parser_int() => ParserInteger()
//! Operation that succeeds only at the end of the text. It reads nothing.
def parser_eof() => ParserEnd()
//! Operation that skips spaces, tabs and line breaks. It succeeds also when there are none.
def parser_spaces() => ParserSpaces()
//! Ordered choice: tries ``left`` and, if that fails, ``right`` from the same position, even when
//! ``left`` had read input. ``right`` is not tried after a committed or fatal failure of ``left``.
//! When both fail, the failure that got further is reported; at equal positions their ``expected``
//! texts are joined with ``or``. Both sides must yield the same value type.
def parser_choice(left,right:auto) =>
    (parserAlternatives=parserAlternativesTag(),left=left,right=right)

//! Builds a ``parsed`` outcome by hand: ``value``, the ``position`` after it and the commit flag.
//! Use it in a ``parser_call`` callback that does not go through ``computation``. The value must be
//! copyable; ``parser_ok_move`` takes the others.
def parser_ok(value:auto(TT); position:int; committed:bool=false) {
    static_assert(typeinfo can_copy(type<TT>),"ParserBuilder requires copyable parsed values")
    return variant<parsed:tuple<value:TT -const -&;position:int;committed:bool>;failure:ParseDiagnostic>(parsed=(value=value,position=position,committed=committed))
}
//! Builds a ``failure`` outcome at ``position`` with the given ``expected`` text; ``unused`` names
//! the value type the outcome would have carried. Line and column are counted from the builder's
//! text, and the builder's commit flag is copied into the diagnostic.
def parser_error(builder:ParserBuilder; position:int; expected:string; unused:type<auto(TT)>) {
    var line=1
    var column=1
    peek_data(builder.text) $(text) {
        for(i in range(position)) {
            if(int(text[i])==10) {line++;column=1} else {column++}
        }
    }
    return variant<parsed:tuple<value:TT -const -&;position:int;committed:bool>;failure:ParseDiagnostic>(failure=ParseDiagnostic(position=position,line=line,column=column,expected=expected,committed=builder.committed,consumed=position>builder.position))
}
//! Runs one parser operation at the builder's position and returns its outcome; the builder itself
//! is not advanced. There is an overload for every operation. Inside ``computation`` write
//! ``op |> bind`` instead, which also moves the cursor past what was read.
def parser_read(builder:ParserBuilder; op:ParserLiteral) {
    var matched=0
    peek_data(builder.text) $(text) {
        peek_data(op.text) $(literal) {
            while(matched<length(literal) && builder.position+matched<length(text)
                    && text[builder.position+matched]==literal[matched]) {matched++}
        }
    }
    if(matched!=length(op.text)) {return parser_error(builder,builder.position+matched,"'{op.text}'",type<string>)}
    return parser_ok(op.text,builder.position+matched,builder.committed)
}
def parser_read(builder:ParserBuilder; _op:ParserInteger) {
    var end=builder.position
    var digits=end
    peek_data(builder.text) $(text) {
        if(end<length(text) && int(text[end])==45) {end++}
        digits=end
        while(end<length(text) && int(text[end])>=48 && int(text[end])<=57) {end++}
    }
    if(end==digits) {return parser_error(builder,end,"integer",type<int>)}
    let number=try_to_int(slice(builder.text,builder.position,end))
    if(!is_ok(number)) {
        var result=parser_error(builder,builder.position,"32-bit integer",type<int>)
        (result as failure).consumed=true
        return result
    }
    return parser_ok(unwrap(number),end,builder.committed)
}
def parser_read(builder:ParserBuilder; _op:ParserSpaces) {
    var end=builder.position
    peek_data(builder.text) $(text) {
        while(end<length(text)) {
            let ch=int(text[end])
            if(ch!=32 && ch!=9 && ch!=10 && ch!=13) {break}
            end++
        }
    }
    return parser_ok(CeUnit(),end,builder.committed)
}
def parser_read(builder:ParserBuilder; _op:ParserEnd) {
    if(builder.position!=length(builder.text)) {return parser_error(builder,builder.position,"end of input",type<CeUnit>)}
    return parser_ok(CeUnit(),builder.position,builder.committed)
}
// Ordered choice preserves the original always-backtracking contract unless cut.
def parser_read(builder:ParserBuilder; op:tuple<parserAlternatives:parserAlternativesTag;left:auto(LL);right:auto(RR)>) {
    var cursor=builder
    cursor.committed=false
    var inscope left <- parser_read(cursor,op.left)
    if(left is parsed) {
        (left as parsed).committed = (left as parsed).committed || builder.committed
        return <- left
    }
    if((left as failure).committed || (left as failure).fatal) {return <- left}
    var inscope right <- parser_read(cursor,op.right)
    if(right is parsed) {
        (right as parsed).committed = (right as parsed).committed || builder.committed
        return <- right
    }
    if((right as failure).committed || (right as failure).fatal) {return <- right}
    if((left as failure).position>(right as failure).position) {
        (left as failure).committed = (left as failure).committed || builder.committed
        return <- left
    }
    if((left as failure).position==(right as failure).position) {
        (left as failure).expected+=" or {(right as failure).expected}"
        (left as failure).committed = (left as failure).committed || builder.committed
        (left as failure).rewound = (left as failure).rewound && (right as failure).rewound
        return <- left
    }
    (right as failure).committed = (right as failure).committed || builder.committed
    return <- right
}

//! Like ``parser_ok``, but moves ``value`` into the outcome, for values that cannot be copied such
//! as arrays. The caller's variable is left empty.
def parser_ok_move(var value:auto(TT); position:int; committed:bool=false) {
    var inscope result:variant<parsed:tuple<value:TT -const -&;position:int;committed:bool>;failure:ParseDiagnostic>
    // Separate assignment avoids shallow copies in SDK AOT variant initializers.
    (result as parsed).value <- value
    (result as parsed).position=position
    (result as parsed).committed=committed
    return <- result
}
//! Wraps an existing ``diagnostic`` into a ``failure`` outcome whose value type is named by
//! ``unused``. Use it to pass a failure on under a different value type.
def parser_failure(diagnostic:ParseDiagnostic; unused:type<auto(TT)>) =>
    <- variant<parsed:tuple<value:TT -const -&;position:int;committed:bool>;failure:ParseDiagnostic>(failure=diagnostic)

// Owning outcomes allow repetitions to return arrays without hidden cloning.
def ce_protocol(_builder:ParserBuilder) => CeOwnedProtocol()
def ce_unwrap(builder:ParserBuilder; var source:variant<parsed:tuple<value:auto(TT);position:int;committed:bool>;failure:ParseDiagnostic>) : TT& {
    unsafe {return (source as parsed).value}
}
def ce_return(builder:ParserBuilder; value:auto) =>
    parser_ok(value,builder.position,builder.committed)
def ce_return_move(builder:ParserBuilder; var value:auto) =>
    <- parser_ok_move(value,builder.position,builder.committed)
def ce_zero(builder:ParserBuilder) => parser_ok(CeUnit(),builder.position,builder.committed)
def ce_delay(builder:ParserBuilder; body:block<():auto(RR)>) : RR => <- invoke(body)
def ce_bind(var builder:ParserBuilder; var source:variant<parsed:tuple<value:auto(TT);position:int;committed:bool>;failure:ParseDiagnostic>;
            next:block<(var value:auto(VV)):auto(RR)>) : RR {
    var inscope owner <- source
    if(owner is failure) {
        var diagnostic=owner as failure
        diagnostic.committed = diagnostic.committed || builder.committed
        return <- variant type<RR>(failure=diagnostic)
    }
    builder.position=(owner as parsed).position
    builder.committed = builder.committed || (owner as parsed).committed
    var inscope result:RR
    result <- invoke(next,(owner as parsed).value)
    return <- result
}
def ce_return_from(var builder:ParserBuilder; var source:variant<parsed:tuple<value:auto(TT);position:int;committed:bool>;failure:ParseDiagnostic>) {
    if(source is parsed) {
        builder.position=(source as parsed).position
        (source as parsed).committed = (source as parsed).committed || builder.committed
        builder.committed=(source as parsed).committed
    } else {(source as failure).committed = (source as failure).committed || builder.committed}
    return <- source
}
def ce_combine(var builder:ParserBuilder; first:variant<parsed:tuple<value:CeUnit;position:int;committed:bool>;failure:ParseDiagnostic>;
               next:block<():auto(RR)>) : RR {
    if(first is failure) {return <- variant type<RR>(failure=first as failure)}
    builder.position=(first as parsed).position
    builder.committed = builder.committed || (first as parsed).committed
    return <- invoke(next)
}
def ce_loop_failed(_builder:ParserBuilder; step:variant<parsed:tuple<value:CeUnit;position:int;committed:bool>;failure:ParseDiagnostic>) =>
    step is failure
def ce_collect_append(var builder:ParserBuilder; var first:variant<parsed:tuple<value:CeUnit;position:int;committed:bool>;failure:ParseDiagnostic>;
                      step:variant<parsed:tuple<value:CeUnit;position:int;committed:bool>;failure:ParseDiagnostic>) {
    if(first is failure) {return}
    first=step
    if(step is parsed) {
        builder.position=(step as parsed).position
        builder.committed = builder.committed || (step as parsed).committed
    }
}
def ce_try_finally(builder:ParserBuilder; body:block<():auto(RR)>; cleanup:block<():void>) : RR {
    var inscope result:RR
    result <- invoke(body)
    invoke(cleanup)
    return <- result
}
def ce_using(builder:ParserBuilder; resource:auto(TT); body:block<(item:TT):auto(RR)>; cleanup:block<(var item:TT):void>) : RR {
    var owner=resource
    var inscope result:RR
    result <- invoke(body,owner)
    invoke(cleanup,owner)
    return <- result
}

//! Operation that runs a named subgrammar: ``callback`` receives a copy of the cursor and returns
//! an outcome, usually from its own ``computation(cursor) { ... }``. It takes a function pointer
//! (``@@grammar``), which captures nothing from the stack.
def parser_call(callback:function<(cursor:ParserBuilder):auto(RR)>) =>
    (parserFunction=true,callback=callback)
def parser_read(builder:ParserBuilder; op:tuple<parserFunction:bool;callback:function<(cursor:ParserBuilder):auto(RR)>>) : RR =>
    <- invoke(op.callback,builder)

//! The operation ``parser_commit()`` returns.
struct ParserCommit {_ce_marker:uint8}
//! Cut: an operation that reads nothing and commits the current computation. A failure after it is
//! ``committed``, so an enclosing ``parser_choice`` does not try its other branch, and
//! ``parser_optional``, ``parser_many`` and ``parser_sep_by`` fail instead of taking it as "absent".
def parser_commit() => ParserCommit()
//! Runs ``source`` and marks its outcome committed, whether it parsed or failed: if ``source``
//! fails, an enclosing ``parser_choice`` does not try its other branch.
def parser_commit(source:auto) => (parserCut=parserCutTag(),source=source)
//! Runs ``source`` as a unit that either matches or backs out: a failure is marked ``rewound`` to
//! the starting position and loses a commit made inside ``source``, so ``parser_choice``,
//! ``parser_optional`` and the repetitions take it as no match there. Fatal failures pass unchanged.
def parser_attempt(source:auto) => (parserAttempt=parserAttemptTag(),source=source)
//! Makes ``source`` optional. Yields ``some(value)`` when it matches, and ``none`` without moving
//! when it fails at its starting position with no input read or was rewound there by
//! ``parser_attempt``. A failure after reading input, a committed or a fatal one stays a failure.
def parser_optional(source:auto) => (parserOptional=parserOptionalTag(),source=source)
//! Repeats ``source`` zero or more times and yields the values as an ``array``; bind it with
//! ``var items & = ... |> bind``. It ends at the first repetition that fails without reading input;
//! one that fails part-way fails the whole operation unless it is wrapped in ``parser_attempt``.
//! A ``source`` that matches without advancing is a fatal failure.
def parser_many(source:auto) => (parserRepeat=parserRepeatTag(),source=source,minimum=0)
//! Like ``parser_many``, but requires at least one match; without one it returns the failure of
//! the first repetition.
def parser_many1(source:auto) => (parserRepeat=parserRepeatTag(),source=source,minimum=1)
//! Reads zero or more ``item`` separated by ``separator`` and yields the items as an ``array``;
//! separator values are dropped. An item must follow every separator, so a trailing separator is a
//! failure. An ``item`` that matches without advancing is a fatal failure.
def parser_sep_by(item,separator:auto) =>
    (parserSeparated=parserSeparatedTag(),item=item,separator=separator)

def parser_read(builder:ParserBuilder; _op:ParserCommit) => parser_ok(CeUnit(),builder.position,true)
def parser_read(builder:ParserBuilder; op:tuple<parserCut:parserCutTag;source:auto(PP)>) {
    var inscope result <- parser_read(builder,op.source)
    if(result is failure) {(result as failure).committed=true}
    else {(result as parsed).committed=true}
    return <- result
}
def parser_read(builder:ParserBuilder; op:tuple<parserAttempt:parserAttemptTag;source:auto(PP)>) {
    var cursor=builder
    cursor.committed=false
    var inscope result <- parser_read(cursor,op.source)
    if(result is failure && !(result as failure).fatal) {
        (result as failure).committed=builder.committed
        (result as failure).rewound=true
        (result as failure).rewind_position=builder.position
        (result as failure).consumed=false
    }
    if(result is parsed) {(result as parsed).committed = (result as parsed).committed || builder.committed}
    return <- result
}
def private parser_absent(diagnostic:ParseDiagnostic; start:int) =>
    !diagnostic.fatal && !diagnostic.committed && ((!diagnostic.consumed && diagnostic.position==start) || (diagnostic.rewound && diagnostic.rewind_position==start))
def parser_read(builder:ParserBuilder; op:tuple<parserOptional:parserOptionalTag;source:auto(PP)>) {
    var cursor=builder
    cursor.committed=false
    var inscope result <- parser_read(cursor,op.source)
    var inscope value:Option<typedecl((result as parsed).value) -const -&>
    if(result is failure) {
        if(!parser_absent(result as failure,builder.position)) {
            var diagnostic=result as failure
            diagnostic.committed = diagnostic.committed || builder.committed
            return <- parser_failure(diagnostic,type<typedecl(value)>)
        }
        value=default<typedecl(value)>
        return <- parser_ok_move(value,builder.position,builder.committed)
    }
    value <- ce_move_some((result as parsed).value)
    return <- parser_ok_move(value,(result as parsed).position,builder.committed || (result as parsed).committed)
}
def private parser_progress_diagnostic(builder:ParserBuilder; operationName:string) {
    let result=parser_error(builder,builder.position,"{operationName}: parser succeeded without advancing input",type<CeUnit>)
    var diagnostic=result as failure
    diagnostic.fatal=true
    return diagnostic
}
def parser_read(builder:ParserBuilder; op:tuple<parserRepeat:parserRepeatTag;source:auto(PP);minimum:int>) {
    var cursor=builder
    cursor.committed=false
    var inscope values:array<typedecl((parser_read(cursor,op.source) as parsed).value) -const -&>
    var committed=builder.committed
    var failed=false
    var diagnostic:ParseDiagnostic
    while(true) {
        var inscope result <- parser_read(cursor,op.source)
        if(result is failure) {
            if(length(values)>=op.minimum && parser_absent(result as failure,cursor.position)) {break}
            diagnostic=result as failure
            diagnostic.committed = diagnostic.committed || committed
            failed=true
            break
        }
        if((result as parsed).position<=cursor.position) {
            diagnostic=parser_progress_diagnostic(cursor,op.minimum==0 ? "many" : "many1")
            failed=true
            break
        }
        values |> emplace <| (result as parsed).value
        cursor.position=(result as parsed).position
        committed = committed || (result as parsed).committed
    }
    if(failed) {return <- parser_failure(diagnostic,type<typedecl(values)>)}
    return <- parser_ok_move(values,cursor.position,committed)
}
def parser_read(builder:ParserBuilder; op:tuple<parserSeparated:parserSeparatedTag;item:auto(PP);separator:auto(SS)>) {
    var cursor=builder
    cursor.committed=false
    var inscope values:array<typedecl((parser_read(cursor,op.item) as parsed).value) -const -&>
    var committed=builder.committed
    var failed=false
    var diagnostic:ParseDiagnostic
    while(true) {
        let start=cursor.position
        if(!empty(values)) {
            var inscope separator <- parser_read(cursor,op.separator)
            if(separator is failure) {
                if(parser_absent(separator as failure,start)) {break}
                diagnostic=separator as failure
                diagnostic.committed = diagnostic.committed || committed
                failed=true
                break
            }
            cursor.position=(separator as parsed).position
            committed = committed || (separator as parsed).committed
        }
        var inscope item <- parser_read(cursor,op.item)
        if(item is failure) {
            if(parser_absent(item as failure,start)) {break}
            diagnostic=item as failure
            diagnostic.committed = diagnostic.committed || committed
            failed=true
            break
        }
        if((item as parsed).position<=cursor.position) {
            diagnostic=parser_progress_diagnostic(cursor,"sep_by")
            failed=true
            break
        }
        values |> emplace <| (item as parsed).value
        cursor.position=(item as parsed).position
        committed = committed || (item as parsed).committed
    }
    if(failed) {return <- parser_failure(diagnostic,type<typedecl(values)>)}
    return <- parser_ok_move(values,cursor.position,committed)
}

def ce_source(builder:ParserBuilder; op:ParserLiteral) => <- parser_read(builder,op)

def ce_source(builder:ParserBuilder; op:ParserInteger) => <- parser_read(builder,op)

def ce_source(builder:ParserBuilder; op:ParserEnd) => <- parser_read(builder,op)

def ce_source(builder:ParserBuilder; op:ParserSpaces) => <- parser_read(builder,op)

def ce_source(builder:ParserBuilder; op:ParserCommit) => <- parser_read(builder,op)

def ce_source(builder:ParserBuilder; op:tuple<parserAlternatives:parserAlternativesTag;left:auto(LL);right:auto(RR)>) =>
    <- parser_read(builder,op)

def ce_source(builder:ParserBuilder; op:tuple<parserFunction:bool;callback:function<(cursor:ParserBuilder):auto(RR)>>) =>
    <- parser_read(builder,op)

def ce_source(builder:ParserBuilder; op:tuple<parserCut:parserCutTag;source:auto(PP)>) =>
    <- parser_read(builder,op)

def ce_source(builder:ParserBuilder; op:tuple<parserAttempt:parserAttemptTag;source:auto(PP)>) =>
    <- parser_read(builder,op)

def ce_source(builder:ParserBuilder; op:tuple<parserOptional:parserOptionalTag;source:auto(PP)>) =>
    <- parser_read(builder,op)

def ce_source(builder:ParserBuilder; op:tuple<parserRepeat:parserRepeatTag;source:auto(PP);minimum:int>) =>
    <- parser_read(builder,op)

def ce_source(builder:ParserBuilder; op:tuple<parserSeparated:parserSeparatedTag;item:auto(PP);separator:auto(SS)>) =>
    <- parser_read(builder,op)
