options gen2
expect 31403
// diagnostic: ce_unwrap
require ../support/game_state_example.das
[export]
def main() {
    let invalid = computation(StateBuilder(GameState())) {
        state_put(42) |> bind
    }
    print("{invalid}\n")
}
