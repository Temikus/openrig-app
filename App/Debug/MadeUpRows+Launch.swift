import Foundation
import RigClient

extension MadeUpRows {
    /// OPENRIG_DEBUG_ROW=<file>, read once at launch: rows to show that nobody sent. RigStore adds them to the queue;
    /// ActionStore refuses every action on them. None in a release build.
    static let launch: MadeUpRows = {
        #if DEBUG
            MadeUpRows(
                json: ProcessInfo.processInfo.environment["OPENRIG_DEBUG_ROW"].flatMap {
                    FileManager.default.contents(atPath: $0)
                })
        #else
            MadeUpRows(json: nil)
        #endif
    }()
}
