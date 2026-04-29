import SwiftUI


/// Helper for comparing lane output states in onChange observer
struct LaneOutputState: Equatable {
    let id: UUID
    let mappingId: UUID?
    let offset: Int
    let count: Int
}
