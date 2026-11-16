options gen2
require computation/computation
require identity_builder
[export]
def main() {
    let result=computation(ResultBuilder()) {let n=ok(20, type<string>) |> bind;return n+22}
    assert(result is ok && result as ok==42)
    let custom=computation(IdentityBuilder()) {let n=(value=21) |> bind;return n*2}
    assert(custom.value==42)
    print("External integration OK\n")
}
