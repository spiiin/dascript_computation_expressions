options gen2
require dastest/testing_boost public
require ../packages/computation/computation.das
struct Resource { id:int }
var opens=0
var closes=0
var log=""
var steps=0
def acquire(id:int) {
 opens++
 return Resource(id=id)
}
def ce_dispose(var r:Resource) { closes++; log+="{r.id}"; r.id=0 }
def reset() { opens=0; closes=0; log=""; steps=0 }
def make_sequence() {
 return <- computation(SequenceBuilder()) {
  let a=acquire(1) |> use_resource
  let b=acquire(2) |> use_resource
  try_finally($ {
   steps++
   yield a.id+b.id
   steps++
   yield 4
  }, $ {log+="F"; log+="!"})
 }
}
def return_early() : int {
 var inscope seq <- make_sequence()
 for(v in seq) {return v}
 return 99
}
[export]
def main() {
 reset()
 { var inscope unused <- make_sequence() }
 assert(opens==0 && closes==0 && log=="")
 {
  var inscope seq <- make_sequence()
  for(v in seq) {assert(v==3); break}
  assert(opens==2 && closes==2 && log=="F!21" && steps==1)
 }
 assert(closes==2)
 reset()
 {
  var inscope seq <- make_sequence()
  var count=0
  for(v in seq) {count++}
  assert(count==2 && closes==2 && log=="F!21" && steps==2)
 }
 reset()
 let early=return_early()
 assert(early==3)
 assert(closes==2 && log=="F!21")
 reset()
 {
  var inscope seq <- computation(SequenceBuilder()) {
   for(i in range(1,4)) {
    let r=acquire(i) |> use_resource
    yield r.id
   }
  }
  var count=0
  for(v in seq) {count++; assert(opens==count && closes==count-1)}
  assert(opens==3 && closes==3 && log=="123")
 }
 reset()
 {
  var inscope seq <- computation(SequenceBuilder()) {
   try_finally($ {yield 1}, $ {log+="a"})
   assert(log=="a")
   try_finally($ {}, $ {log+="b"})
   assert(log=="ab")
   yield 2
  }
  for(v in seq) {}
  assert(log=="ab")
 }
 reset()
 {
  var inscope seq <- make_sequence()
  var value=0
  let got=next(seq,value)
  assert(got && value==3 && closes==0)
  unsafe {delete seq}
  assert(closes==2 && log=="F!21")
 }
 reset()
 {
  var inscope seq <- computation(SequenceBuilder()) {
   let a=acquire(1) |> use_resource
   let n=[2,3] |> bind
   let b=acquire(n) |> use_resource
   yield a.id+b.id
  }
  for(v in seq) {}
  assert(opens==3 && closes==3 && log=="231")
 }
 reset()
 {
  var inscope seq <- make_sequence()
  sequence_each(seq, $(v:int) {log+="v"})
  assert(log=="vvF!21" && closes==2)
 }
 print("sequence resource checks OK\n")
}

[test]
def test_sequence_resource() {
    main()
}
