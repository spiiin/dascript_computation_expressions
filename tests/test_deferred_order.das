options gen2
require dastest/testing_boost public
require ../packages/computation/computation.das
require ../packages/computation/deferred_computation.das
var events=""
struct Observed {}
def builder() { events+="B"; return Observed() }
def environment() { events+="D"; return [7] }
def ce_protocol(b:Observed) { events+="P"; return CeValueProtocol() }
def ce_return(b:Observed; value:int) { events+="T"; return ok(value, type<string>) }
def ce_run(b:Observed; result:Result<int;string>) { events+="R"; return result as ok }
[export]
def main() {
    let baseline=heap_bytes_allocated()
    {
        var inscope task <- deferred(builder(),environment()) $(snapshot) {
            events+="E"
            return snapshot[0]
        }
        assert(events=="BD")
        let first=run_deferred(task)
        assert(first==7 && events=="BDETR")
        let second=run_deferred(task)
        assert(second==7 && events=="BDETRETR")
    }
    let after=heap_bytes_allocated()
    assert(after==baseline)
    print("deferred ordering checks OK\n")
}

[test]
def test_deferred_order() {
    main()
}
