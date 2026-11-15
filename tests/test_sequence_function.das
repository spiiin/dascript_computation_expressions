options gen2
require ../lib/computation.das
require ../lib/coroutine_builder.das
require ../lib/async_sequence_builder.das
require ../lib/task_runtime.das

// [sequence], [async_sequence] and [coroutine] turn a function body into a
// stream, as [task] turns one into a task. The declared result of a sequence
// is the type of one element; a coroutine declares none.

[sequence]
def evens(limit : int) : int {
    for (value in range(limit)) {
        if (value % 2 == 0) {
            yield value
        }
    }
}

// The written-out form of the same function.
def evens_by_hand(limit : int) {
    return <- computation(SequenceBuilder(type<int>)) {
        for (value in range(limit)) {
            if (value % 2 == 0) {
                yield value
            }
        }
    }
}

struct Point {
    x : int
    y : int
}
[sequence]
def diagonal(count : int) : Point {
    for (i in range(count)) {
        yield Point(x = i, y = i)
    }
}

// A `var` argument is moved into the sequence, so it need not be copyable.
[sequence]
def doubled(var values : array<int>) : int {
    for (value in values) {
        yield value * 2
    }
}

var journal = ""

[coroutine]
def patrol(name : string) {
    journal += "{name} start; "
    yield next_frame()
    journal += "{name} done; "
}

[async_sequence]
def readings(count : int) : int {
    for (i in range(count)) {
        task_after_polls(1, CeUnit()) |> bind
        yield 10 + i
    }
}

[task]
def consume() : int {
    var stream & = readings(3) |> use_resource
    var sum = 0
    while (true) {
        let item = async_sequence_next(stream) |> bind
        if (item is none) { break }
        sum += item as some
    }
    return sum
}

[export]
def main() {
    var total = 0
    for (value in evens(7)) { total += value }
    verify(total == 12)
    static_assert(typeinfo typename(evens(1)) == typeinfo typename(evens_by_hand(1)))

    var points = 0
    for (point in diagonal(3)) { points += point.x + point.y }
    verify(points == 6)

    var data <- [1, 2, 3]
    var twice = 0
    for (value in doubled(data)) { twice += value }
    verify(twice == 12 && empty(data))

    // A coroutine is cold: nothing runs until it is stepped.
    var inscope walker <- patrol("npc")
    verify(journal == "")
    var frames = 0
    for (frame in walker) { frames++ }
    verify(journal == "npc start; npc done; " && frames > 0)

    var inscope job <- consume()
    while (task_poll(job) == TaskStatus.Waiting) {}
    verify(task_value(job) == 33)
    print("Sequence function checks OK\n")
}
