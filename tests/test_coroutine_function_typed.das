options gen2
require ../packages/computation/computation.das
require ../packages/computation/coroutine_builder.das

// A coroutine produces no values, so [coroutine] rejects a declared result
// instead of ignoring it.
[coroutine]
def patrol(steps : int) : int {
    yield next_frame()
}

[export]
def main() {
    var inscope walker <- patrol(1)
}
