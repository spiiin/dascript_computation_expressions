options gen2
expect 30910
// diagnostic: left side can't be constant
require ../packages/computation/computation.das
[export]
def main() {
    let values=fixed_array(1,2)
    let result=computation(ResultBuilder()) {for (v,i in values,range(2)) {v+=1}}
}
