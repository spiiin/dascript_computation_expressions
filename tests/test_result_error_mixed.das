options gen2
require ../lib/computation.das

enum LoadError {
    NotFound
}
[export]
def main() {
    // A source with another error type is not converted: the bind is rejected.
    let bad = computation(ResultBuilder(type<LoadError>)) {
        let value = result_ok(1) |> bind
        return value
    }
    print("{bad}\n")
}
