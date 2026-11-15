options gen2
require ../packages/computation/computation.das
[export]
def main() {
 let result=computation(ResultBuilder()) {try_with($ {return 1}, $ {return 2})}
}
