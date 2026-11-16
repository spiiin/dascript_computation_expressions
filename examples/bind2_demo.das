options gen2
require ../packages/computation/computation.das
require ../packages/computation/validation_builder.das

def price(name:string) { return name=="Sword" ? ok(30, type<string>) : err("Unknown item",type<int>) }
[export]
def main() {
    let purchase=computation(ResultBuilder()) {
        let p=ok("Sword", type<string>) |> and_bind(ok(50, type<string>)) |> bind
        let cost=price(p.first) |> bind
        if (p.second<cost) { return err("Not enough gold",type<int>) |> return_from }
        else { return p.second-cost }
    }
    assert(purchase is ok && purchase as ok==20)
    var inscope loadouts <- computation(ListBuilder(type<int>)) {
        let p=[10,20] |> and_bind([1,2]) |> bind
        let score=p.first+p.second
        let bonus=[0,100] |> bind
        return score+bonus
    }
    assert(length(loadouts)==8 && loadouts[0]==11 && loadouts[7]==122)
    print("bind2 demo OK\n")
}
