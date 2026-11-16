options gen2
require dastest/testing_boost public
require ../packages/computation/computation.das
require ../packages/computation/deferred_computation.das
var freed=0
var opened=0
var closed=0
var visited=0
var log=""
struct Snapshot {
    values:array<int>
    def finalize {
        if (length(values)>0) { freed++; log+="D" }
        delete values
    }
}
struct Resource {}
def acquire() { opened++; return Resource() }
def ce_dispose(var resource:Resource) { closed++; log+="R" }
def make_task() {
    var inscope data:Snapshot
    data.values <- [10,20]
    return <- deferred(SequenceBuilder(type<int>),data) $(snapshot) {
        let resource=acquire() |> use_resource
        try_finally($ {
            snapshot.values[0]++
            visited++
            yield snapshot.values[0]
            visited++
            yield snapshot.values[1]
        }, $ { assert(snapshot.values[0]==11); log+="F" })
    }
}
def return_early() : int {
    var inscope task <- make_task()
    var inscope seq <- run_deferred(task)
    for (value in seq) { return value }
    return 0
}
def reset() { freed=0; opened=0; closed=0; visited=0; log="" }
[export]
def main() {
    let baseline=heap_bytes_allocated()
    for (round in range(10)) {
        reset()
        {
            var inscope task <- make_task()
            assert(freed==1 && opened==0)
            var inscope first <- run_deferred(task)
            var inscope second <- task |> run_deferred
            assert(freed==1 && opened==0 && visited==0)
            delete task
            assert(freed==2)
            log=""
            var a=0
            var b=0
            verify(next(first,a))
            verify(next(second,b))
            assert(a==11 && b==11 && opened==2 && freed==2)
            sequence_close(first)
            assert(freed==3 && closed==1 && log=="FRD")
            var total=b
            for (value in second) { total+=value }
            assert(total==31 && freed==4 && closed==2 && log=="FRDFRD")
        }
        let after=heap_bytes_allocated()
        assert(after==baseline)
    }
    reset()
    {
        var inscope task <- make_task()
        for (round in range(10)) {
            {
                var inscope seq <- run_deferred(task)
                for (value in seq) { assert(value==11); break }
                assert(freed==round+2 && closed==round+1)
            }
        }
        {
            var inscope unstarted <- run_deferred(task)
        }
        assert(freed==12 && opened==10 && closed==10)
    }
    assert(freed==13)
    let afterBreak=heap_bytes_allocated()
    assert(afterBreak==baseline)
    reset()
    let early=return_early()
    assert(early==11 && freed==3 && closed==1)
    let afterReturn=heap_bytes_allocated()
    assert(afterReturn==baseline)
    {
        var inscope task <- deferred(SequenceBuilder(type<int>),[1,2]) $(snapshot) { if(false) { yield snapshot[0] } }
        var inscope seq <- run_deferred(task)
        var count=0
        for(value in seq) { count++ }
        assert(count==0)
    }
    let afterEmpty=heap_bytes_allocated()
    assert(afterEmpty==baseline)
    print("deferred sequence lifetime checks OK\n")
}

[test]
def test_deferred_sequence() {
    main()
}
