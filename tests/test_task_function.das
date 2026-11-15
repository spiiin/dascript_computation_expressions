options gen2
require ../lib/computation.das
require ../lib/task_runtime.das

// [task] and [task_result] turn a function body into a task: the declared
// result is the value the task produces.

var steps = 0

[task]
def doubled(value : int) : int {
    steps++
    return value * 2
}

// The written-out form of the same function.
def doubled_by_hand(value : int) : Task<int> {
    return <- computation(TaskBuilder(type<int>)) {
        steps++
        return value * 2
    }
}

[task]
def sum_of(first, second : int) : int {
    let a = doubled(first) |> bind
    let b = doubled(second) |> bind
    return a + b
}

[task]
def describe_sum(first, second : int) : string {
    let total = sum_of(first, second) |> bind
    if (total > 10) {
        return "big {total}"
    }
    return "small {total}"
}

[task]
def countdown(start : int) : array<int> {
    var seen : array<int>
    var left = start
    while (left > 0) {
        let value = doubled(left) |> bind
        seen |> push(value)
        left--
    }
    return <- seen
}

[task_result]
def checked(value : int) : int {
    let accepted = task_after_polls(1, value < 0 ? result_error("negative", type<int>) : result_ok(value)) |> bind
    return accepted
}

[task_result]
def checked_sum(first, second : int) : int {
    let a = checked(first) |> bind
    let b = checked(second) |> bind
    return a + b
}

[task]
def private hidden() : int {
    return 7
}

// The value type may come from an argument of a generic function.
[task]
def twice(value : auto(T)) : T {
    return value + value
}

// The value type may itself be a template type.
[task]
def positive(value : int) : Option<int> {
    let twiceValue = doubled(value) |> bind
    return twiceValue > 0 ? some(twiceValue) : default<Option<int>>
}

// The result is declared, not inferred, so a task function can call itself.
[task]
def factorial(n : int) : int {
    if (n <= 1) {
        return 1
    }
    let rest = factorial(n - 1) |> bind
    return n * rest
}

[task]
def greet(name : string = "world"; times : int = 1) : string {
    var text = ""
    for (i in range(times)) {
        text += "hello {name} "
    }
    return text
}

// A `var` argument is moved into the task, so it need not be copyable.
[task]
def total(var values : array<int>) : int {
    var sum = 0
    for (value in values) {
        let twice = doubled(value) |> bind
        sum += twice
    }
    return sum
}

[task]
def drain(var tasks : array<Task<int>>) : int {
    var sum = 0
    for (index in range(length(tasks))) {
        let value = tasks[index] |> bind
        sum += value
    }
    return sum
}

// The task works on its own copy of a copyable `var` argument.
[task]
def counted(var count : int; step : int) : int {
    while (count < 10) {
        count += step
        task_after_polls(1, CeUnit()) |> bind
    }
    return count
}

// Nothing the macro generates may clash with a name the function uses.
[task]
def relay(source : int; stream : int) : int {
    let waited = doubled(source + stream) |> bind
    return waited
}

def finish(var task : Task<auto(T)>) {
    while (task_poll(task) == TaskStatus.Waiting) {}
    static_if (typeinfo can_copy(task.value)) {
        return task_value(task)
    } else {
        return <- task_value(task)
    }
}

[export]
def main() {
    // A task is cold: calling the function runs nothing.
    var inscope first <- doubled(21)
    verify(steps == 0)
    verify(finish(first) == 42 && steps == 1)

    // The sugar and the written-out form have the same type.
    var inscope byHand <- doubled_by_hand(21)
    static_assert(typeinfo typename(first) == typeinfo typename(byHand))
    var declared : Task<int> <- doubled(1)
    verify(finish(declared) == 2)
    delete declared

    var inscope sum <- sum_of(1, 2)
    verify(finish(sum) == 6)

    var inscope big <- describe_sum(3, 4)
    verify(finish(big) == "big 14")
    var inscope small <- describe_sum(1, 2)
    verify(finish(small) == "small 6")

    var inscope counted <- countdown(3)
    var values <- finish(counted)
    verify(length(values) == 3 && values[0] == 6 && values[2] == 2)
    delete values

    var inscope ok <- checked_sum(1, 2)
    let good = finish(ok)
    verify(good is ok && (good as ok) == 3)
    var inscope failed <- checked_sum(1, -2)
    let bad = finish(failed)
    verify(bad is err && (bad as err) == "negative")
    var typed : Task<Result<int;string>> <- checked(5)
    let five = finish(typed)
    verify(five is ok && (five as ok) == 5)
    delete typed

    var inscope seven <- hidden()
    verify(finish(seven) == 7)

    var inscope numbers <- twice(21)
    var inscope letters <- twice("ab")
    verify(finish(numbers) == 42 && finish(letters) == "abab")
    // A generic's T is `string const` for a literal; the task value is plain.
    var named : Task<string> <- twice("cd")
    verify(finish(named) == "cdcd")
    delete named
    var inscope present <- positive(2)
    var inscope absent <- positive(-2)
    verify(finish(present) is some && finish(absent) is none)
    var inscope product <- factorial(5)
    verify(finish(product) == 120)
    var inscope greeting <- greet()
    var inscope greetings <- greet("das", 2)
    verify(finish(greeting) == "hello world " && finish(greetings) == "hello das hello das ")

    var data <- [1, 2, 3]
    var inscope summed <- total(data)
    verify(empty(data) && finish(summed) == 12)
    var jobs : array<Task<int>>
    jobs |> emplace(doubled(1))
    jobs |> emplace(doubled(2))
    var inscope drained <- drain(jobs)
    verify(empty(jobs) && finish(drained) == 6)
    var start = 4
    var inscope stepped <- counted(start, 3)
    verify(finish(stepped) == 10 && start == 4)
    var inscope relayed <- relay(1, 2)
    verify(finish(relayed) == 6)
    print("Task function checks OK\n")
}
