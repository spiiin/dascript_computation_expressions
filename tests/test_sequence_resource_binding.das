options gen2
require ../packages/computation/computation.das
[export]
def main() {
 var inscope seq <- computation(SequenceBuilder()) {
  1 |> use_resource
  yield 1
 }
}
