options gen2
expect 31211
// diagnostic: payload must own its data
require ../packages/computation_task/async_sequence_builder.das
[export]
def main() {let builder=AsyncSequenceBuilder(type<int?>)}
