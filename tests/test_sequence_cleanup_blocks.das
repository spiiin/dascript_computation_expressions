options gen2
require ../packages/computation/computation.das
[export]
def main() {
 var inscope seq <- computation(SequenceBuilder()) {
  try_finally($ {yield 1}, 42)
 }
}
