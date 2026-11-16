options gen2
expect 30107
expect 30165:3
expect 30316
expect 30341
expect 30820:2
expect 31211
// diagnostic: ce_source must return a source, not void
require ../packages/computation/computation.das
struct BadSource {}
def ce_source(builder:ResultBuilder; source:BadSource) {}
[export]
def main() {let value=computation(ResultBuilder()) {let n=BadSource() |> bind;return n} }
