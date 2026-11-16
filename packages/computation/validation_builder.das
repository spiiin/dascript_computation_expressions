options gen2
module validation_builder public
require ./builder_protocol.das public
require daslib/templates
require daslib/templates_boost
require daslib/typemacro_boost

//! ``ValidationBuilder``: checks that report every error instead of the first one. ``validation_zip``, or an
//! ``and_bind`` group, combines independent checks and collects the errors of all of them; an ordinary
//! ``bind`` stops at the first invalid source. Require it in addition to ``computation``. Values are copied.

//! Builder of a computation that produces ``Validation<T>``: ``return value`` gives ``valid``, and a
//! ``bind`` of an invalid source ends the computation with the errors of that source.
struct ValidationBuilder {_ce_marker:uint8}
//! The errors of a failed validation: ``messages`` holds the texts, one per line, in the order the checks
//! were combined, and ``count`` is their number.
struct ValidationErrors {
    messages : string
    count : int
}

//! What a validation produces: the value, or every error collected so far.
//! ``Validation<int>`` is the variant that ``validation_ok`` and ``validation_error``
//! return, so a variable, a field or a function result can be declared with it.
// A type macro serves the modules that require this one, not this module:
// the functions below spell the variant out.
[template_variant(TT)]
struct template Validation {
    valid : TT
    invalid : ValidationErrors
}

//! A successful validation that holds a copy of ``value``.
def validation_ok(value : auto(TT)) : variant<valid:TT -const -&;invalid:ValidationErrors> =>
    variant<valid:TT -const -&;invalid:ValidationErrors>(valid=value)
//! A failed validation with the single error ``message``; the ``type<T>`` witness names the type of the
//! value that a success would hold.
def validation_error(message : string; unused : type<auto(TT)>) : variant<valid:TT -const -&;invalid:ValidationErrors> =>
    variant<valid:TT -const -&;invalid:ValidationErrors>(invalid=ValidationErrors(messages=message, count=1))
//! Combines two validations that are already computed: the pair ``(first, second)`` of their values when
//! both are valid, otherwise the errors of both, those of ``left`` first.
def validation_zip(left : variant<valid:auto(AA);invalid:ValidationErrors>;
                   right : variant<valid:auto(BB);invalid:ValidationErrors>) {
    if (left is invalid) {
        var errors = left as invalid
        if (right is invalid) {
            errors.messages += "\n{(right as invalid).messages}"
            errors.count += (right as invalid).count
        }
        return variant<valid:tuple<first:AA -const -&;second:BB -const -&>;invalid:ValidationErrors>(invalid=errors)
    }
    if (right is invalid) {
        return variant<valid:tuple<first:AA -const -&;second:BB -const -&>;invalid:ValidationErrors>(invalid=right as invalid)
    }
    return variant<valid:tuple<first:AA -const -&;second:BB -const -&>;invalid:ValidationErrors>(valid=(first=left as valid, second=right as valid))
}

def ce_protocol(_builder : ValidationBuilder) => CeDirectProtocol()
[inline]
def ce_direct_failed(builder : ValidationBuilder; source : variant<valid:auto(TT);invalid:ValidationErrors>) : bool =>
    source is invalid
def ce_direct_failure(builder : ValidationBuilder; source : variant<valid:auto(TT);invalid:ValidationErrors>;
                      witness : auto(RR)?) : RR => variant type<RR>(invalid=source as invalid)
[inline]
def ce_unwrap(builder : ValidationBuilder; source : variant<valid:auto(TT);invalid:ValidationErrors>) : TT =>
    source as valid
[inline]
def ce_return(builder : ValidationBuilder; value : auto(TT)) => validation_ok(value)
def ce_return_from(builder : ValidationBuilder; source : variant<valid:auto(TT);invalid:ValidationErrors>) : variant<valid:TT -const -&;invalid:ValidationErrors> =>
    source
def ce_zero(_builder : ValidationBuilder) => validation_ok(CeUnit())
def ce_bind(builder : ValidationBuilder; source : variant<valid:auto(TT);invalid:ValidationErrors>;
            next : block<(value:TT):auto(RR)>) : RR {
    if (source is invalid) { return variant type<RR>(invalid=source as invalid) }
    return invoke(next, source as valid)
}
def ce_combine(builder : ValidationBuilder; first : variant<valid:CeUnit;invalid:ValidationErrors>;
               next : block<():auto(RR)>) : RR {
    if (first is invalid) { return variant type<RR>(invalid=first as invalid) }
    return invoke(next)
}
def ce_loop_append(_builder : ValidationBuilder; first, step : variant<valid:CeUnit;invalid:ValidationErrors>) {
    if (first is invalid) { return first }
    return step
}
def ce_loop_failed(_builder : ValidationBuilder; step : variant<valid:CeUnit;invalid:ValidationErrors>) : bool =>
    step is invalid




def ce_merge_sources(builder : ValidationBuilder; left : variant<valid:auto(AA);invalid:ValidationErrors>;
                     right : variant<valid:auto(BB);invalid:ValidationErrors>) =>
                         validation_zip(left, right)

def ce_bind_return(builder : ValidationBuilder; source : variant<valid:auto(TT);invalid:ValidationErrors>;
                   mapper : block<(value:TT):auto(UU)>) : variant<valid:UU -const -&;invalid:ValidationErrors> {
    if (source is invalid) { return variant<valid:UU -const -&;invalid:ValidationErrors>(invalid=source as invalid) }
    return variant<valid:UU -const -&;invalid:ValidationErrors>(valid=invoke(mapper, source as valid))
}

def ce_bind2_return(builder:ValidationBuilder;
                    left:variant<valid:auto(AA);invalid:ValidationErrors>; right:variant<valid:auto(BB);invalid:ValidationErrors>;
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):auto(UU)>) : typedecl(ce_return(builder,default<UU>)) {
    if (left is invalid) {
        var errors=left as invalid
        if (right is invalid) { errors.messages+="\n{(right as invalid).messages}"; errors.count+=(right as invalid).count }
        return variant type<typedecl(ce_return(builder,default<UU>))>(invalid=errors)
    }
    if (right is invalid) { return variant type<typedecl(ce_return(builder,default<UU>))>(invalid=right as invalid) }
    return variant type<typedecl(ce_return(builder,default<UU>))>(valid=invoke(mapper,ce_source_pair(left as valid,right as valid)))
}

// Grouped bind: the continuation already returns an outcome.
def ce_bind2(builder:ValidationBuilder;
                    left:variant<valid:auto(AA);invalid:ValidationErrors>; right:variant<valid:auto(BB);invalid:ValidationErrors>;
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):auto(RR)>) : RR {
    if (left is invalid) {
        var errors=left as invalid
        if (right is invalid) { errors.messages+="\n{(right as invalid).messages}"; errors.count+=(right as invalid).count }
        return variant type<RR>(invalid=errors)
    }
    if (right is invalid) { return variant type<RR>(invalid=right as invalid) }
    return invoke(mapper,ce_source_pair(left as valid,right as valid))
}
