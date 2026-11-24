import Foundation
import RigModel

/// Everything waiting on the person, as the phone lists it: the app contract's asks, and what the Mac's relay adds
/// (prompts, asks without options, held rows, FYIs, seats down, and other rigs' counts).
public struct NeedsYouList: Equatable, Sendable {
    /// Seats stopped at a permission prompt, in the rig open on the Mac.
    public var prompts: [RelayNeedsYouItem]
    /// Asks with options, answered through the app contract.
    public var asks: [AppRequest]
    /// Asks without options, held rows and FYIs: answered with Reply, Got it or Done.
    public var rows: [RelayNeedsYouItem]
    public var seatsDown: [RelayNeedsYouItem]
    /// Other rigs' prompts and seats down, one count per rig. They're on that rig's seat list, not here.
    public var elsewhere: [RelayNeedsYou.RigCount]

    public init(asks: [AppRequest], relay: RelayNeedsYou?) {
        self.asks = asks
        let items = relay?.items ?? []
        prompts = items.filter { $0.kind == "prompt" }
        seatsDown = items.filter { $0.kind == "seat" }
        // The Mac lists asks with options too; those are the contract's asks above.
        let contract = Set(asks.map(\.id))
        rows = items.filter { Self.rowKinds.contains($0.kind) && !contract.contains($0.row ?? "") }
        elsewhere = relay?.attentionElsewhere ?? []
    }

    static let rowKinds: Set<String> = ["ask", "held", "fyi"]
}

extension AppRequest {
    /// `orch-lead@openrig-app` → `openrig-app`.
    public var askerRig: String? {
        guard let asker, let at = asker.firstIndex(of: "@") else { return nil }
        return String(asker[asker.index(after: at)...])
    }
}

extension NeedsYouList {

    /// For the tab's badge: everything listed, and other rigs' counts, so it never reads as nothing waiting.
    public var count: Int {
        prompts.count + asks.count + rows.count + seatsDown.count + elsewhere.reduce(0) { $0 + $1.count }
    }

    public var isEmpty: Bool { count == 0 }

    /// One rig's share of `count`, for the Rigs tab: the rigs' counts add up to Needs you's badge.
    public func count(inRig rig: String) -> Int {
        let listed = (prompts + rows + seatsDown).filter { $0.rig == rig }.count
        return listed + asks.filter { $0.askerRig == rig }.count
            + elsewhere.filter { $0.rig == rig }.reduce(0) { $0 + $1.count }
    }

    public enum RowAction: Sendable, Equatable { case reply, gotIt, done }

    /// As the Mac's For You panel: an FYI is read and closed; an ask or a held row is answered, then closed.
    public static func actions(for item: RelayNeedsYouItem) -> [RowAction] {
        switch item.kind {
        case "fyi": [.reply, .gotIt]
        case "ask", "held": [.reply, .done]
        default: []
        }
    }
}
