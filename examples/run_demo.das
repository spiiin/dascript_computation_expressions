options gen2
require ../packages/computation/computation_macro.das
require ../support/report_builder.das

def buy(gold:int) {
    return computation(ReportBuilder(title="Buy sword")) {
        let p=ok(gold, type<string>) |> and_bind(ok(30, type<string>)) |> bind
        if (p.first<p.second) { return err("Not enough gold",type<int>) |> return_from }
        else { return p.first-p.second }
    }
}
[export]
def main() {
    let bought=buy(50)
    assert(bought is completed && (bought as completed).value==20)
    let denied=buy(10)
    assert(denied is failed && (denied as failed).message=="Not enough gold")
    print("{(bought as completed).title}: gold left {(bought as completed).value}\n")
    print("{(denied as failed).title}: {(denied as failed).message}\n")
    print("run demo OK\n")
}
