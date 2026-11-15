options gen2
require ../packages/computation/computation.das
require ../packages/computation_task/task_runtime.das
require ../packages/computation/deferred_computation.das

// TaskResultBuilder(type<T>, type<E>) is a task that fails with any copyable
// error type; [task_result] names that type in the declared result.

enum LoadError {
    NotFound
    Denied
    Broken
}

def find(id : int) : Result<int;LoadError> {
    if (id < 0) { return err(LoadError.NotFound, type<int>) }
    if (id > 100) { return err(LoadError.Denied, type<int>) }
    return ok(id, type<LoadError>)
}

var reached = 0

// The written-out form.
def lookup(id : int) {
    return <- computation(TaskResultBuilder(type<int>, type<LoadError>)) {
        let found = task_after_polls(1, find(id)) |> bind
        reached++
        return found * 2
    }
}

[task_result]
def load(first, second : int) : Result<string;LoadError> {
    let a = lookup(first) |> bind
    // A task without a result of its own binds as before.
    task_after_polls(1, CeUnit()) |> bind
    let b = lookup(second) |> bind
    return "{a}+{b}"
}

// A task that fails with a string, as the library's own sources do.
[task_result]
def fetch(id : int) : int {
    let value = task_after_polls(1, id < 0 ? result_error("no such id", type<int>) : result_ok(id)) |> bind
    return value
}

def classify(message : string) : LoadError {
    return message == "no such id" ? LoadError.NotFound : LoadError.Broken
}

// task_map_error gives it the computation's error type.
[task_result]
def fetched(id : int) : Result<int;LoadError> {
    let value = task_map_error(fetch(id), @@classify) |> bind
    return value * 2
}

// and_bind waits for both tasks; the failure of either ends the computation.
// A task without a result of its own joins the group.
[task_result]
def both(first, second : int) : Result<int;LoadError> {
    let pair = lookup(first) |> and_bind(lookup(second)) |> bind
    let timed = lookup(first) |> and_bind(task_after_polls(2, CeUnit())) |> bind
    return pair.first + pair.second + timed.first
}

def finish(var task : Task<auto(T)>) {
    while (task_poll(task) == TaskStatus.Waiting) {}
    return task_value(task)
}

[export]
def main() {
    var inscope good <- load(1, 2)
    let both = finish(good)
    verify(both is ok && (both as ok) == "2+4" && reached == 2)

    // The first failure ends the task: the second lookup never starts.
    reached = 0
    var inscope missing <- load(-1, 2)
    let first = finish(missing)
    verify(first is err && (first as err) == LoadError.NotFound && reached == 0)

    reached = 0
    var inscope denied <- load(1, 500)
    let second = finish(denied)
    verify(second is err && (second as err) == LoadError.Denied && reached == 1)

    var declared : Task<Result<int;LoadError>> <- lookup(3)
    let six = finish(declared)
    verify(six is ok && (six as ok) == 6)
    delete declared

    var inscope mapped <- fetched(21)
    let answer = finish(mapped)
    verify(answer is ok && (answer as ok) == 42)
    var inscope unmapped <- fetched(-1)
    let failure = finish(unmapped)
    verify(failure is err && (failure as err) == LoadError.NotFound)

    var inscope pair <- both(1, 2)
    let sum = finish(pair)
    verify(sum is ok && (sum as ok) == 8)
    var inscope right <- both(1, 500)
    let refused = finish(right)
    verify(refused is err && (refused as err) == LoadError.Denied)

    // The combinators keep the error type of their tasks.
    var inscope all <- task_result_when_all(lookup(1), lookup(-1))
    let group = finish(all)
    verify(group is err && (group as err) == LoadError.NotFound)
    var jobs : array<Task<Result<int;LoadError>>>
    jobs |> emplace(lookup(1))
    jobs |> emplace(lookup(2))
    var inscope every <- task_result_when_all(jobs)
    var inscope values <- finish(every)
    verify(values is ok && length(values as ok) == 2 && (values as ok)[1] == 4)
    var inscope raced <- task_result_race(lookup(3), lookup(500))
    let winner = finish(raced)
    verify(winner is ok && (winner as ok).value == 6)

    // deferred saves the computation and its data; each run is a new task.
    var inscope saved <- deferred(TaskResultBuilder(type<int>, type<LoadError>), [4, -4]) $(ids) {
        var sum = 0
        for (id in ids) {
            let found = task_after_polls(1, find(id)) |> bind
            sum += found
        }
        return sum
    }
    var inscope run <- run_deferred(saved)
    let outcome = finish(run)
    verify(outcome is err && (outcome as err) == LoadError.NotFound)
    print("Task error type checks OK\n")
}
