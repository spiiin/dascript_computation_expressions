options gen2
require dastest/testing_boost public
require ../packages/computation/computation.das
require ../packages/computation/deferred_computation.das
[export]
def main() {
    var inscope task <- deferred(SequenceBuilder(type<int>)) { yield 1; yield 2 }
    for (i in range(2)) {
        var inscope seq <- run_deferred(task)
        var sum=0
        for (value in seq) { sum+=value }
        assert(sum==3)
    }
    print("deferred iterator checks OK\n")
}

[test]
def test_deferred_iterator() {
    main()
}
