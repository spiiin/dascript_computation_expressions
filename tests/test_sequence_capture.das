options gen2
expect 30192
expect 30295
expect 30838
expect 31003
// diagnostic: implicit capture by move requires unsafe
require ../packages/computation/computation.das
[export]
def main() {
 var inscope input : array<int>
 input |> push(7)
 var inscope seq <- computation(SequenceBuilder()) {
  let v=input |> bind
  yield v
 }
 for(v in seq) { print("{v}\n") }
}
