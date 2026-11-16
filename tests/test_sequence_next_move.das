options gen2
require dastest/testing_boost public
require ../support/deferred_move_support.das

def interleaved() {
    let baseline=heap_bytes_allocated()
    {
        var inscope task <- deferred_loot_sequence()
        var inscope a <- run_deferred(task)
        var inscope b <- run_deferred(task)
        delete task
        let snapshots=snapshot_freed
        var inscope first:Loot
        var inscope second:Loot
        for(i in range(3)) {
            let gotA=sequence_next_move(a,first)
            let gotB=sequence_next_move(b,second)
            assert(gotA && gotB && first.items[0]==10*(i+1) && second.items[0]==10*(i+1))
            first.items[0]=999
            assert(second.items[0]!=999)
        }
        let doneA=sequence_next_move(a,first)
        let doneB=sequence_next_move(b,second)
        assert(!doneA && !doneB && first.items[0]==999 && second.items[0]==30 && snapshot_freed==snapshots+2)
        assert(feeds_opened==feeds_closed)
        let again=sequence_next_move(a,first)
        assert(!again && first.items[0]==999)
    }
    let current=heap_bytes_allocated();assert(current==baseline)
}
def raw_values() {
    let baseline=heap_bytes_allocated()
    {
        var inscope stream <- generator<Loot> {yield <- loot(1);yield <- loot(2);return false}
        var inscope value <- loot(99)
        var count=0
        while(sequence_next_move(stream,value)) {count++}
        assert(count==2 && value.items[0]==2)
    }
    {
        var inscope stream <- loot_sequence()
        var inscope value:Loot
        while(sequence_next_move(stream,value)) {break}
        sequence_close(stream)
        assert(value.items[0]==10 && feeds_opened==feeds_closed)
    }
    let current=heap_bytes_allocated();assert(current==baseline)
}

def arrays() {
    let baseline=heap_bytes_allocated()
    {
        var inscope stream <- computation(SequenceBuilder(type<array<int>>)) {yield <- [1,2];yield <- [3,4]}
        var inscope value <- [99]
        var count=0
        while(sequence_next_move(stream,value)) {count++}
        assert(count==2 && length(value)==2 && value[0]==3)
    }
    let current=heap_bytes_allocated();assert(current==baseline)
}

[export]
def main() {
    for(round in range(10)) {interleaved();raw_values();arrays()}
    print("sequence_next_move ownership checks OK\n")
}

[test]
def test_sequence_next_move() {
    main()
}
