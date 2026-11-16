options gen2
expect 31400
// diagnostic: LoadError
require ../packages/computation/computation.das

enum LoadError {
    NotFound
}
[export]
def main() {
    // A source with another error type is not converted: the bind is rejected.
    let bad = computation(ResultBuilder(type<LoadError>)) {
        let value = ok(1, type<string>) |> bind
        return value
    }
    print("{bad}\n")
}
