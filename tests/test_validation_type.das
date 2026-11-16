options gen2
require dastest/testing_boost public
require ../packages/computation/computation_macro.das
require ../packages/computation/validation_builder.das

// Validation<T> names the type a validation produces: a function result, an
// argument, a variable and a field can be declared with it.
struct Form {
    age : Validation<int>
}

def checked_age(age : int) : Validation<int> {
    if (age < 0) { return validation_error("age is negative", type<int>) }
    return validation_ok(age)
}

def outcome_text(outcome : Validation<int>) : string {
    if (outcome is valid) { return "valid {outcome as valid}" }
    return (outcome as invalid).messages
}

[export]
def main() {
    let good : Validation<int> = checked_age(30)
    assert(good is valid && (good as valid) == 30)
    var form = Form(age = checked_age(-1))
    assert(form.age is invalid && (form.age as invalid).count == 1)
    assert(outcome_text(good) == "valid 30")
    assert(outcome_text(form.age) == "age is negative")
    // The name is the type a computation returns, not a look-alike.
    let doubled = computation(ValidationBuilder()) {
        let age = checked_age(21) |> bind
        return age * 2
    }
    assert(typeinfo stripped_typename(doubled) == typeinfo stripped_typename(type<Validation<int>>))
    assert(doubled is valid && (doubled as valid) == 42)
    let both = computation(ValidationBuilder()) {
        let pair = checked_age(-1) |> validation_zip(checked_age(-2)) |> bind
        return pair.first + pair.second
    }
    assert(both is invalid && (both as invalid).count == 2)
    print("validation type name checks OK\n")
}

[test]
def test_validation_type() {
    main()
}
