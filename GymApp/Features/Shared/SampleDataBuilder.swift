import Foundation
import SwiftData

/// Builds the fixtures described by `PreviewSupport.Scenario`.
@MainActor
enum SampleDataBuilder {
    static func populate(_ context: ModelContext, scenario: PreviewSupport.Scenario) {
        _ = context
        _ = scenario
    }
}
