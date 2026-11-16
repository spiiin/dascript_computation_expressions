options gen2
require dastest/testing_boost public
require ../packages/computation/computation.das
[export]
def main() {
 var inscope values <- computation(ListBuilder(type<int>)) {
  yield 1
  [2,3] |> yield_from
  for(i in range(2)) { yield i+4 }
  yield 6
 }
 assert(length(values)==6)
 for(i in range(6)) { assert(values[i]==i+1) }
 print("list yield checks OK\n")
}

[test]
def test_list_yield() {
    main()
}
