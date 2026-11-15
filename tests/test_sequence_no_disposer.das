options gen2
expect 30341
// diagnostic: ce_dispose
require ../packages/computation/computation.das
[export]
def main() {
 var inscope seq <- computation(SequenceBuilder()) {
  let bad=1 |> use_resource
  yield bad
 }
}
