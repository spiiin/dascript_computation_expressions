options gen2
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
