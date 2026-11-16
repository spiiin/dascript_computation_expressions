options gen2
require ../support/json_resource_example.das
var journal=""
def document(text:string) : JsonResource {
 let parsed=open_document(text)
 if(parsed is err) {panic(parsed as err)}
 return parsed as ok
}
def enemy_health() {
 return <- computation(SequenceBuilder(type<int>)) {
  let data=document("\{\"health\":42\}") |> use_resource
  try_finally($ {
   yield int(data.node?["health"] as _longint)
   yield 43
  }, $ {journal+="scope closed; "; print("scope closed\n")})
 }
}
[export]
def main() {
 {
  var inscope health <- enemy_health()
  assert(resource_opens==0)
  for(value in health) {print("first health: {value}\n"); break}
  assert(resource_opens==1 && resource_closes==1)
 }
 {
  var inscope health <- enemy_health()
  for(value in health) {print("health: {value}\n")}
  assert(resource_closes==2)
 }
 print("sequence resources demo OK\n")
}
