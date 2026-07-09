import Foundation
import PuttyBridge

@main
@MainActor
enum PuttyBridgePhase3ExitTest {
    static func main() {
        let result = putty_bridge_phase3_exit_test()
        exit(result == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
