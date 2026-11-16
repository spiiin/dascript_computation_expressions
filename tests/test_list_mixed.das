options gen2
expect 31403
// diagnostic: ce_unwrap
// diagnostic: cannot bind a source of type variant<err:string;ok:int>
// anchor: |> bind
require ../packages/computation/computation.das
[export]
def main() {
    var inscope invalid <- computation(ListBuilder(type<int>)) { ok(1, type<string>) |> bind }
}
