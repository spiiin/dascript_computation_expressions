options gen2
expect 30295
expect 31003
// diagnostic: implicit capture by move requires unsafe
require ../packages/computation/computation.das
[export]
def main() {
 var inscope input : array<int>
 input |> push(7)
 var inscope seq <- computation(SequenceBuilder(type<int>)) {
  let v=input |> bind
  yield v
 }
}
