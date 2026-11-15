options gen2
options max_infer_passes=128
require ../packages/computation/computation_macro.das
require ../packages/computation_task/async_sequence_builder.das
require ../packages/computation_task/task_scheduler.das

var produced=0
var closed=0
[async_sequence]
def readings() : int {
    try_finally($ {
        for(i in range(3)) {
            task_delay_ms(10) |> bind
            produced++
            yield 20+i
        }
    },$ {closed++})
}
[task]
def consume() : int {
    var stream & = readings() |> use_resource
    var sum=0
    while(true) {
        let item=async_sequence_next(stream) |> bind
        if(item is none) {break}
        print("Reading: {item as some}\n")
        sum+=item as some
    }
    return sum
}
[export]
def main() {
    var inscope scheduler <- task_scheduler(type<int>)
    let id=task_spawn(scheduler,consume(),TaskTimeout(after_ms=100))
    for(now in range(0,50)) {task_tick(scheduler,now)}
    verify(task_status(scheduler,id)==TaskStatus.Succeeded && task_value(scheduler,id)==63)
    verify(produced==3 && closed==1)
    print("Async sequence demo OK\n")
}
