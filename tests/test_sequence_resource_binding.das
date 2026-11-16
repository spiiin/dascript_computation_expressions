options gen2
expect 50503
// diagnostic: expected 'let resource
require ../packages/computation/computation.das
[export]
def main() {
 var inscope seq <- computation(SequenceBuilder(type<int>)) {
  1 |> use_resource
  yield 1
 }
}
