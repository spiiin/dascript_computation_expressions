options gen2
require ../lib/computation_macro.das
require ../lib/task_scheduler.das
require daslib/match
require ../lib/sequence_builder.das

enum Route {
    First
    Second
    Skip
}

var trace : array<int>
var released : int
var guard_checks : int
var finally_count : int

struct MatchResource {
    id : int
}

def ce_dispose(var resource : MatchResource) { released++; trace |> push <| -resource.id }

def accept(value : int) : bool { guard_checks++; return value > 0 }

[task]
def matching(route : Route) : int {
    var value = 0
    match (route) {
        if (Route.First || Route.Second) {
            var resource & = MatchResource(id = 10) |> use_resource
            trace |> push <| resource.id
            let amount = task_after_polls(1, 4) |> bind
            value += amount
            match (route) {
                if (Route.First) {
                    task_delay_ms(20) |> bind
                    value += 3
                }
                if (_) { value += 2 }
            }
            trace |> push <| value
        }
        if (_) { value = 9 }
    }
    trace |> push <| 100
    return value
}

variant Choice {
    number : int
    skip : bool
}

[task]
def captured(choice : Choice) : int {
    var number = 99
    var resource & = MatchResource(id = 20) |> use_resource
    match (choice) {
        if (Choice(number = $v(number))) {
            let copy = number
            task_delay_ms(5) |> bind
            return copy + number
        }
    }
    return number
}

[task]
def loop_match() : int {
    var total = 0
    for (i in range(5)) {
        match (i) {
            if (0) { task_delay_ms(1) |> bind; continue }
            if (1 || 2) {
                var resource & = MatchResource(id = 30) |> use_resource
                let value = task_after_polls(1, i) |> bind
                total += value
            }
            if (_) { task_delay_ms(1) |> bind; break }
        }
        total += 10
    }
    return total
}

[task_result]
def failed_match() : int {
    match (Route.First) {
        if (Route.First) {
            var resource & = MatchResource(id = 40) |> use_resource
            let value = task_after_polls(1, result_error("match failure", type<int>)) |> bind
            trace |> push <| 999
            return value
        }
    }
    return 0
}

[task]
def guarded(value : int) : int {
    match (value) {
        if ($v(n) && accept(n)) {
            let first = task_after_polls(1, n) |> bind
            task_delay_ms(2) |> bind
            return first + 1
        }
        if (_) { return -1 }
    }
    return 0
}

[task]
def throwing_match() : int {
    match (Route.First) {
        if (Route.First) {
            try_finally($ {
                var resource & = MatchResource(id = 60) |> use_resource
                task_delay_ms(2) |> bind
                panic("match exception")
            }, $ { finally_count++ })
        }
    }
    return 0
}

def check_sequence() {
    var inscope values <- computation(SequenceBuilder(type<int>)) {
        match (Route.Second) {
            if (Route.First) { yield 0 }
            if (Route.Second) {
                var resource & = MatchResource(id = 50) |> use_resource
                let n = [2, 3] |> bind
                yield n * 10
            }
        }
        yield 40
    }
    var inscope actual : array<int>
    for (value in values) { actual |> push <| value }
    verify(length(actual) == 3 && actual[0] == 20 && actual[1] == 30 && actual[2] == 40)
}

[export]
def main() {
    var inscope scheduler <- task_scheduler(type<int>)
    let active = task_spawn(scheduler, matching(Route.First))
    task_tick(scheduler, 0)
    verify(length(trace) == 1 && trace[0] == 10 && released == 0)
    task_tick(scheduler, 1)
    task_tick(scheduler, 20)
    verify(task_status(scheduler, active) == TaskStatus.Waiting)
    task_tick(scheduler, 21)
    verify(task_status(scheduler, active) == TaskStatus.Succeeded)
    verify(task_value(scheduler, active) == 7 && released == 1)
    verify(length(trace) == 4 && trace[1] == 7 && trace[2] == -10 && trace[3] == 100)
    let cancelled = task_spawn(scheduler, matching(Route.First))
    task_tick(scheduler, 30)
    let before_cancel = released
    verify(task_cancel(scheduler, cancelled))
    verify(released == before_cancel + 1)
    let count = length(trace)
    task_tick(scheduler, 60)
    verify(length(trace) == count)

    let second = task_spawn(scheduler, matching(Route.Second))
    let fallback = task_spawn(scheduler, matching(Route.Skip))
    let pattern = task_spawn(scheduler, captured(Choice(number = 6)))
    let unmatched = task_spawn(scheduler, captured(Choice(skip = true)))
    let loop = task_spawn(scheduler, loop_match())
    for (now in range(100, 130)) { task_tick(scheduler, now) }
    verify(task_value(scheduler, second) == 6 && task_value(scheduler, fallback) == 9)
    verify(task_value(scheduler, pattern) == 12 && task_value(scheduler, unmatched) == 99)
    verify(task_value(scheduler, loop) == 23)

    let guarded_task = task_spawn(scheduler, guarded(8))
    let fallback_guard = task_spawn(scheduler, guarded(0))
    let throwing = task_spawn(scheduler, throwing_match())
    let cancelled_inner = task_spawn(scheduler, matching(Route.First))
    task_tick(scheduler, 140)
    task_tick(scheduler, 141)
    verify(guard_checks == 2 && task_value(scheduler, fallback_guard) == -1)
    let before_inner_cancel = released
    verify(task_cancel(scheduler, cancelled_inner))
    verify(released == before_inner_cancel + 1)
    for (now in range(142, 170)) { task_tick(scheduler, now) }
    verify(task_value(scheduler, guarded_task) == 9 && guard_checks == 2,
           "Selected arms and guards must not be re-evaluated after suspension")
    verify(task_status(scheduler, throwing) == TaskStatus.Failed && finally_count == 1)
    verify(released == before_inner_cancel + 2,
           "Both cancelled and failed arms must release their resource")
    verify(task_error(scheduler, throwing) != "")

    var inscope result_scheduler <- task_scheduler(type<Result<int; string>>)
    let failed = task_spawn(result_scheduler, failed_match())
    task_tick(result_scheduler, 0)
    let before_failure = released
    task_tick(result_scheduler, 1)
    verify(task_status(result_scheduler, failed) == TaskStatus.Succeeded)
    let result = task_value(result_scheduler, failed)
    verify(result is err && result as err == "match failure" && released == before_failure + 1)
    for (item in trace) { verify(item != 999) }
    let before_sequence = released
    check_sequence()
    verify(released == before_sequence + 1)
    delete trace
    print("CE match OK: nested bind, patterns, shadowing, guards, loops, resources, errors, cancellation\n")
}
