import Foundation
import RigClient

extension RequestLog {
    /// OPENRIG_DEBUG_REQUESTS=<file>, read once at launch: appends a line to the file for each request to the daemon.
    /// Off in a release build.
    static func installAtLaunch() {
        #if DEBUG
            if let path = ProcessInfo.processInfo.environment["OPENRIG_DEBUG_REQUESTS"] {
                install(appending(toFile: path))
            }
        #endif
    }
}
