options gen2
require dastest/testing_boost public
require ../packages/computation/computation_macro.das
require ../packages/computation_task/task_scheduler.das
require daslib/strings_boost
require daslib/rtti

var globalScheduler:typedecl(task_scheduler(type<int>))
var currentId:TaskId
var operation=0
var closed=0

def pending() {
    return <- task_from_poll(@(){return task_pending(type<int>)},@(){closed++})
}
def reenter() {
    if(operation==0) {let n=task_tick(globalScheduler,0)}
    elif(operation==1) {let id=task_spawn(globalScheduler,pending())}
    elif(operation==2) {let n=task_cancel(globalScheduler,currentId)}
    elif(operation==3) {task_scheduler_close(globalScheduler)}
    elif(operation==4) {let n=task_forget(globalScheduler,currentId)}
    elif(operation==5) {let n=task_prune(globalScheduler)}
    else {task_configure(globalScheduler,TaskSchedulerConfig())}
}
def reentrant() {
    return <- task_from_poll(@(){reenter();return task_ready(1)},@(){closed++})
}
def fail() {return <- task_from_poll(@(){panic("native failure");return task_ready(0)},@(){closed++})}

def guards() {
    for(index in range(7)) {
        operation=index
        globalScheduler <- task_scheduler(type<int>)
        currentId=task_spawn(globalScheduler,reentrant())
        let survivor=task_spawn(globalScheduler,task_after_polls(0,9))
        verify(task_tick(globalScheduler,0)==0)
        verify(task_status(globalScheduler,currentId)==TaskStatus.Failed)
        verify(starts_with(task_error(globalScheduler,currentId),"task scheduler: mutation"))
        verify(task_value(globalScheduler,survivor)==9)
        delete globalScheduler
    }
}
def identities() {
    var inscope left <- task_scheduler(type<int>)
    var inscope right <- task_scheduler(type<int>)
    let id=task_spawn(left,pending())
    verify(!task_valid(right,id) && !task_valid(left,TaskId()))
    var caught=false
    try {let n=task_cancel(right,id)} recover {caught=true}
    verify(caught && task_active_count(left)==1)
    var inscope moved <- left
    verify(task_valid(moved,id) && !task_valid(left,id))
    caught=false
    try {let n=task_tick(left,0)} recover {caught=true}
    verify(caught)
    verify(!task_forget(moved,id))
    verify(task_cancel(moved,id) && !task_cancel(moved,id))
    verify(task_forget(moved,id) && !task_valid(moved,id))
    let replacement=task_spawn(moved,task_after_polls(0,4))
    verify(replacement.slot==id.slot && replacement.generation==id.generation+uint64(1))
    verify(!task_valid(moved,id) && task_slot_count(moved)==1)
    caught=false
    try {let n=task_value(moved,id)} recover {caught=true}
    verify(caught)
    verify(task_tick(moved,10)==0 && task_value(moved,replacement)==4)
    // A slot at the last generation is retired instead of wrapping.
    moved.frames[0].records[0].slot.generation=uint64(-1)
    var last=replacement;last.generation=uint64(-1)
    verify(task_forget(moved,last))
    let next=task_spawn(moved,pending())
    verify(next.slot!=last.slot && task_slot_count(moved)==2)
}
def errors_and_close() {
    var inscope scheduler <- task_scheduler(type<int>)
    let failed=task_spawn(scheduler,fail())
    let good=task_spawn(scheduler,task_after_polls(0,8))
    verify(task_tick(scheduler,0)==0)
    verify(task_status(scheduler,failed)==TaskStatus.Failed && starts_with(task_error(scheduler,failed),"native failure"))
    verify(task_value(scheduler,good)==8)
    let neverStarted=task_spawn(scheduler,pending())
    task_scheduler_close(scheduler)
    verify(task_active_count(scheduler)==0 && task_count(scheduler)==3)
    verify(task_status(scheduler,neverStarted)==TaskStatus.Cancelled && task_value(scheduler,good)==8)
    task_scheduler_close(scheduler)
    verify(task_tick(scheduler,0)==0)
    verify(task_prune(scheduler)==3)
}
[export]
def main() {
    guards();identities();errors_and_close()
    let baseline=heap_bytes_allocated()
    for(i in range(16)) {guards();identities();errors_and_close()}
    verify(heap_bytes_allocated()==baseline)
    print("Task scheduler safety checks OK\n")
}

[test]
def test_task_scheduler_safety() {
    main()
}
