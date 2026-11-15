options gen2
require dastest/testing_boost public
require ../packages/computation/computation.das
require ../packages/computation_task/task_runtime.das
require ../packages/computation_task/task_jobque.das
require daslib/rtti
require daslib/fio
def compute(n:int) {var total=0;for(i in range(n)) {total+=i};return total}
[export]
def main() {
 with_job_que() {
  var inscope queue <- task_job_queue()
  var inscope runtime <- task_runtime()
  var inscope ticket <- task_spawn(runtime,task_jobque(queue,100,@@compute))
  // The worker finishes in wall-clock time: wait against a deadline and pause
  // between ticks. A fixed tick count is not a time bound, compiled code (JIT,
  // AOT) runs through it before the worker thread has done its part.
  let started=ref_time_ticks()
  var now=0
  while(get_time_usec(started)<30000000) {
   task_tick(runtime,now);now++
   if(task_status(ticket)==TaskStatus.Succeeded) {break}
   sleep(1u)
  }
  verify(task_status(ticket)==TaskStatus.Succeeded && task_value(ticket) as ok==4950)
  task_jobque_collect(queue)
 }
 verify(task_jobque_channels()==0)
 print("Task jobque checks OK\n")
}

[test]
def test_task_jobque() {
    main()
}
