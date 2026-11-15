options gen2
require dastest/testing_boost public
require ../packages/computation/computation.das
[export]
def main() {
    let baseline=heap_bytes_allocated()
    for (iteration in range(20)) {
        {
            var inscope values <- computation(ListBuilder()) {
                yield 1
                for (i in range(3)) { yield i }
                if (true) { yield 7 }
                yield 9
            }
            assert(length(values)==6 && values[0]==1 && values[5]==9)
        }
        {
            var inscope values <- computation(ListBuilder()) {
                let p=ce_merge_sources(ListBuilder(),fixed_array(1,2),fixed_array(10,20)) |> bind
                let n=p.first+p.second
                return n
            }
            assert(length(values)==4 && values[3]==22)
        }
        let after=heap_bytes_allocated()
        assert(after==baseline)
    }
    print("collect temporary checks OK\n")
}

[test]
def test_collect_temporaries() {
    main()
}
