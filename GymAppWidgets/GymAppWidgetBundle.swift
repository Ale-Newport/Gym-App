import WidgetKit
import SwiftUI

@main
struct GymAppWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextWorkoutWidget()
    }
}

struct NextWorkoutWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextWorkoutWidget", provider: SnapshotProvider()) { entry in
            Text(entry.snapshot.nextWorkoutTitle ?? "—")
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next Workout")
        .supportedFamilies([.systemSmall])
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: SharedSnapshotStore.shared.read() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: SharedSnapshotStore.shared.read() ?? .placeholder)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(1800))))
    }
}
