options gen2
expect 50503
// diagnostic: shared locals require copyable values
require ../packages/computation/computation.das
[export]
def main() {
 var inscope seq <- computation(SequenceBuilder(type<int>)) {
  var inscope x:array<int>
  try_finally($ {yield length(x)}, $ {})
 }
}
