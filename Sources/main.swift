import AppKit

let application = NSApplication.shared
if CommandLine.arguments.contains("--self-test") {
    let testDelegate = RecordingSelfTest()
    application.delegate = testDelegate
    application.run()
} else {
    let delegate = CompanionDelegate()
    application.delegate = delegate
    application.run()
}
