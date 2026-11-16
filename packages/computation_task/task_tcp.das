options gen2
module task_tcp public
require ./task_builder.das public
require daslib/network
require daslib/strings_boost

//! A one-line TCP request as a task: ``task_tcp_request_line`` connects, sends a request and completes
//! with the first line of the reply. Require it for simple line-based exchanges with a server from
//! a task; all of it runs on the thread that creates and polls the task.

var private tcp_created=0
var private tcp_released=0
//! Returns counters for leak checks: connections ``created`` and ``released`` by
//! ``task_tcp_request_line``, and those still ``active``, which is 0 once every task has ended.
def task_tcp_stats() => (created=tcp_created,released=tcp_released,active=tcp_created-tcp_released)

// One bounded line per connection. connect() has the SDK's bounded synchronous
// connect phase; tick()/receive are nonblocking. All calls stay on one thread.
class CeTaskTcpLine : Client {
    bytes:array<uint8>
    error:string
    complete:bool
    limit:int
    def CeTaskTcpLine(max_bytes:int) {
        super()
        limit=max_bytes
        make_client_adapter()
        tcp_created++
    }
    def finalize() {
        close()
        delete bytes
        delete super.self
        tcp_released++
    }
    def override onConnect() {}
    def override onDisconnect() {if(!complete && empty(error)) {error="connection closed before a complete line"}}
    def override onLog(message:string) {}
    def override onError(message:string;code:int) {if(empty(error)) {error="{message} ({code})"}}
    def override onData(buffer:uint8?;size:int) {
        if(complete || !empty(error)) {return}
        for(i in range(size)) {
            let byte=unsafe(buffer[i])
            if(byte==uint8(10)) {complete=true;break}
            if(length(bytes)>=limit) {error="line exceeds max_bytes";break}
            bytes |> push(byte)
        }
    }
}

//! Connects to ``host``:``port``, sends ``request`` and returns a ``Task<Result<string;string>>`` with the
//! reply up to its first line feed (not included); err if the connection fails, closes before a full
//! line or the line exceeds ``max_bytes``. Connecting and sending happen in this call and may block
//! for ``connect_timeout_ms``; receiving happens in polls and does not block. The connection closes
//! when the task ends. Panics on a limit out of range or a request longer than 4096 bytes.
def task_tcp_request_line(host:string;port:int;request:string;max_bytes:int=65536;connect_timeout_ms:int=1000) {
    if(port<1 || port>65535 || max_bytes<1 || connect_timeout_ms<1) {panic("task_tcp_request_line: invalid limits")}
    if(length(request)>4096) {panic("task_tcp_request_line: request is limited to 4096 bytes")}
    var reader=new CeTaskTcpLine(max_bytes)
    if(reader.connect(host,port,connect_timeout_ms)) {
        peek_data(request) $(data) {
            if(!empty(data)) {if(!reader.send(unsafe(addr<uint8?>(data[0])),length(data))) {reader.error="failed to send request"}}
        }
    } elif(empty(reader.error)) {reader.error="connection failed"}
    return <- task_from_poll(@() {
        reader.tick()
        if(!empty(reader.error)) {return task_ready(err(reader.error,type<string>))}
        if(reader.complete) {return task_ready(ok(string(reader.bytes), type<string>))}
        return task_pending(type<Result<string;string>>)
    },@() {unsafe {delete reader}})
}
