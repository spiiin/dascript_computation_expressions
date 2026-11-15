options gen2
expect 30344
// diagnostic: initialization type mismatch
require ../packages/computation/computation.das
[export]
def main() {
 var inscope seq <- computation(SequenceBuilder()) {
  var x:int="wrong"
  try_finally($ {yield x}, $ {})
 }
}
