options gen2
require ../lib/computation.das

// The builder needs the element type before the body is known, so [sequence]
// rejects a function that leaves its result to inference.
[sequence]
def numbers(limit : int) {
    for (value in range(limit)) {
        yield value
    }
}

[export]
def main() {
    for (value in numbers(3)) {
        print("{value}\n")
    }
}
