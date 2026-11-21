import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--render-app") {
            SnapshotRunner.runApp()
        } else if CommandLine.arguments.contains("--render") {
            SnapshotRunner.run()
        } else {
            GreeceApp.main()
        }
    }
}
