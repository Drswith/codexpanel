import AppKit
import Foundation

enum CLIViewURLOpener {
    static func open(_ url: URL, appURL: URL?) -> Bool {
        if let appURL {
            return self.open(url, withApplicationAt: appURL)
        }
        return NSWorkspace.shared.open(url)
    }

    private static func open(_ url: URL, withApplicationAt appURL: URL) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        let semaphore = DispatchSemaphore(value: 0)
        var didOpen = false

        NSWorkspace.shared.open(
            [url],
            withApplicationAt: appURL,
            configuration: configuration
        ) { _, error in
            didOpen = error == nil
            semaphore.signal()
        }

        let timeout = DispatchTime.now() + .seconds(10)
        guard semaphore.wait(timeout: timeout) == .success else {
            return false
        }
        return didOpen
    }
}
