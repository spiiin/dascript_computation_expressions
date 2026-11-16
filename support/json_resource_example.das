options gen2
module json_resource_example public
require ../packages/computation/computation.das public
require ../examples/builders/writer_result_builder.das public
require daslib/json_boost public

struct JsonResource { node : JsonValue const? }
var resource_opens = 0
var resource_closes = 0

def open_document(text : string) {
    var error : string
    let node = read_json(text, error)
    if (node == null) { return err(error, type<JsonResource>) }
    resource_opens++
    return ok(JsonResource(node=node), type<string>)
}
def ce_dispose(var resource : JsonResource) {
    unsafe { delete_json(reinterpret<JsonValue?>(resource.node)) }
    resource.node = null
    resource_closes++
}
def read_health(text : string; reject : bool) {
    return computation(WriterResultBuilder()) {
        tell("read document\n") |> bind
        let loaded = open_document(text) |> bind
        let document = loaded |> use_resource
        if (reject) { err("rejected after opening", type<int>) |> bind }
        let health = document.node?["health"]
        if (!(health is _longint)) { return err("expected integer health", type<int>) |> return_from }
        else { return int(health as _longint) }
    }
}


