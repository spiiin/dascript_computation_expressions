options gen2
module coroutine_builder public
require ./builder_protocol.das public
require ./sequence_runtime.das public
require ./sequence_function.das public

//! Frame-stepped coroutines: ``computation(CoroutineBuilder()) { ... }`` turns a block into a lazy
//! ``iterator<CoroutineFrame>`` that suspends at ``yield next_frame()`` and ``yield wait_frames(n)``.
//! Require it to write scripts that advance a step per frame and to drive one with
//! ``coroutine_resume``; ``coroutine_scheduler`` drives many of them at once.

//! Builder for ``computation(CoroutineBuilder()) { ... }``. The block becomes an
//! ``iterator<CoroutineFrame>`` that runs nothing until it is first resumed; the caller owns it and
//! resumes or cancels it. Inside the block ``yield`` takes a ``CoroutineWait``, and
//! ``child |> yield_from`` runs another coroutine to its end, a frame of the child per frame of the
//! parent; the parent owns the child and closes it if the parent is cancelled.
struct CoroutineBuilder {_ce_marker:uint8}
//! A request to stay suspended for ``frames`` frame boundaries. Make one with ``next_frame`` or
//! ``wait_frames`` and ``yield`` it inside a coroutine.
struct CoroutineWait {frames:int}
//! One frame boundary: the element a coroutine's iterator produces each time it suspends. It
//! carries no data.
struct CoroutineFrame {_ce_marker:uint8}

//! A wait for one frame: ``yield next_frame()`` suspends the coroutine until the next resume.
def next_frame() => CoroutineWait(frames=1)
//! A wait for ``frames`` frames: after ``yield wait_frames(n)`` the coroutine suspends ``n`` times
//! before its body continues, so ``wait_frames(0)`` does not suspend. Panics if ``frames`` is negative.
def wait_frames(frames:int) {
    if (frames<0) {panic("wait_frames: frame count must be non-negative")}
    return CoroutineWait(frames=frames)
}
def ce_protocol(_builder:CoroutineBuilder) => ce_sequence_protocol(type<CoroutineWait>)

// Expand each suspension into exactly N frame boundaries. The outer iterator
// closes this owner when it is closed.
def ce_sequence_run(_builder:CoroutineBuilder; var source:iterator<CoroutineWait>) : iterator<CoroutineFrame> {
    var frames <- generator<CoroutineFrame> capture(<-source) {
        var request=CoroutineWait()
        while (ce_sequence_next_value(source,request)) {
            if (request.frames<0) {panic("wait_frames: frame count must be non-negative")}
            for (i in range(request.frames)) {yield CoroutineFrame()}
        }
        return false
    } finally {ce_sequence_finalize($ {sequence_close(source)})}
    return <- ce_sequence_protect(frames)
}

// Await a child through `child |> yield_from`, forwarding one boundary per tick.
// The adapter owns the child, including when the parent is cancelled.
def ce_source(_builder:CoroutineBuilder; var child:iterator<CoroutineFrame>) : iterator<CoroutineWait> {
    var requests <- generator<CoroutineWait> capture(<-child) {
        var frame=CoroutineFrame()
        while (ce_sequence_next_value(child,frame)) {yield next_frame()}
        return false
    } finally {ce_sequence_finalize($ {sequence_close(child)})}
    return <- ce_sequence_protect(requests)
}

//! Runs the coroutine up to its next frame boundary. Returns true if it suspended there and false
//! if it has finished; a finished coroutine is closed, and resuming it again returns false.
//! A panic in the body is not caught here and reaches the caller.
def coroutine_resume(var task:iterator<CoroutineFrame>) : bool {
    var frame=CoroutineFrame()
    let more=ce_sequence_next_value(task,frame)
    if (!more) {sequence_close(task)}
    return more
}
//! Closes the coroutine without running the rest of its body; the resources the body holds through
//! ``use_resource`` are released. A coroutine that was never resumed runs nothing at all.
//! Calling it again, or resuming afterwards, is harmless: the iterator is left empty.
def coroutine_cancel(var task:iterator<CoroutineFrame>) {sequence_close(task)}


