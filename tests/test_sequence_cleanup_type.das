options gen2
expect 30295
expect 30341
expect 30838
// diagnostic: ce_sequence_scoped
require ../packages/computation/computation.das
[export]
def main() {
 var inscope seq <- computation(SequenceBuilder(type<int>)) {
  try_finally($ {yield 1}, $ {return 42})
 }
}
