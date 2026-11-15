options gen2
expect 30941
// diagnostic: variant<err:string;ok:int>
require ../packages/computation/computation.das
[export]
def main() {
    let bad = computation(ResultBuilder()) {
        for (i in range(3)) { return i }
    }
    print("{bad}\n")
}
