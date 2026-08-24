import SwiftUI
import UserNotifications

/// Reminders.
///
/// Nothing is ever scheduled that the user did not switch on, and every change re-applies the whole
/// configuration through `NotificationService.applySettings` rather than scheduling one extra
/// request. Applying the whole picture each time is what keeps the pending queue and the settings
/// row from drifting apart — a stale weekly reminder that nobody can find to cancel is worse than
/// no reminder at all.
struct NotificationSettingsView: View {
    @State private var model = SettingsViewModel()
    @State private var notifications = NotificationSettingsViewModel()

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    init() {}

    private var isEnabled: Bool { model.settings?.notificationsEnabled ?? false }

    var body: some View {
        SettingsScreen(model: model) {
            SettingsList {
                SettingsErrorBanner(model: model)
                statusSection
                trainingSection
                restTimerSection
                weightSection
                mealSection
            }
        }
        .task {
            let service = environment.notificationService
            let coordinator = notifications
            let settingsModel = model
            await coordinator.refresh(service: service)
            // Any settings write re-applies the whole schedule. Weak, because the model owns the
            // closure and the closure would otherwise own the model straight back.
            settingsModel.onSettingsChanged = { [weak settingsModel] in
                guard let settingsModel else { return }
                coordinator.apply(service: service, settings: settingsModel)
            }
        }
        .onDisappear { model.onSettingsChanged = nil }
        .onChange(of: scenePhase) { _, phase in
            // The user may have changed permission in iOS Settings while the app was away.
            if phase == .active {
                Task { await notifications.refresh(service: environment.notificationService) }
            }
        }
        .navigationTitle(L("settings.notifications.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { isEnabled },
                set: { isOn in
                    Task {
                        await notifications.setEnabled(
                            isOn,
                            service: environment.notificationService,
                            settings: model
                        )
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("settings.notifications.enable"))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("settings.notifications.enable.detail"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.appAccent)
            .disabled(notifications.isRequesting || notifications.status == .denied)
            .frame(minHeight: Metrics.minimumTapTarget)

            if notifications.status == .denied {
                VStack(alignment: .leading, spacing: Metrics.spacing8) {
                    Label {
                        Text(L("settings.notifications.denied"))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "bell.slash.fill").foregroundStyle(Color.appWarning)
                    }
                    Button(L("settings.notifications.openSettings")) { openSystemSettings() }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 280)
                }
                .padding(.vertical, Metrics.spacing4)
            }
        } header: {
            Text(L("settings.notifications.section.permission"))
        } footer: {
            Text(L("settings.notifications.permissionFooter"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Training reminder

    private var trainingSection: some View {
        Section {
            Toggle(isOn: model.settingsBinding(\.trainingReminderEnabled, default: false)) {
                Text(L("settings.notifications.training")).fixedSize(horizontal: false, vertical: true)
            }
            .tint(Color.appAccent)
            .frame(minHeight: Metrics.minimumTapTarget)

            if model.settings?.trainingReminderEnabled ?? false {
                DatePicker(
                    selection: trainingTimeBinding,
                    displayedComponents: .hourAndMinute
                ) {
                    Text(L("settings.notifications.trainingTime")).fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: Metrics.minimumTapTarget)

                SettingsFootnote(text: trainingDaysExplanation)
            }
        } header: {
            Text(L("settings.notifications.section.training"))
        }
        .listRowBackground(Color.appSurface)
        .disabled(!isEnabled)
    }

    /// The reminder repeats on the days the user said they can train, so the screen names them
    /// rather than leaving the user to discover the rule.
    private var trainingDaysExplanation: String {
        let weekdays = model.profile?.availableWeekdays ?? []
        guard !weekdays.isEmpty else { return L("settings.notifications.trainingAllDays") }
        let names = weekdays.sorted().map { L($0.shortLocalizationKey) }.joined(separator: ", ")
        return L("settings.notifications.trainingDays", names)
    }

    private var trainingTimeBinding: Binding<Date> {
        Binding(
            get: {
                Self.date(hour: model.settings?.trainingReminderHour ?? 18,
                          minute: model.settings?.trainingReminderMinute ?? 0)
            },
            set: { newDate in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                model.updateSettings {
                    $0.trainingReminderHour = parts.hour ?? 18
                    $0.trainingReminderMinute = parts.minute ?? 0
                }
            }
        )
    }

    // MARK: - Rest timer

    private var restTimerSection: some View {
        Section {
            Toggle(isOn: model.settingsBinding(\.restTimerNotificationEnabled, default: true)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("settings.notifications.restTimer"))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("settings.notifications.restTimer.detail"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.appAccent)
            .frame(minHeight: Metrics.minimumTapTarget)
        } header: {
            Text(L("settings.notifications.section.restTimer"))
        }
        .listRowBackground(Color.appSurface)
        .disabled(!isEnabled)
    }

    // MARK: - Weight reminder

    private var weightSection: some View {
        Section {
            Toggle(isOn: model.settingsBinding(\.weightReminderEnabled, default: false)) {
                Text(L("settings.notifications.weight")).fixedSize(horizontal: false, vertical: true)
            }
            .tint(Color.appAccent)
            .frame(minHeight: Metrics.minimumTapTarget)

            if model.settings?.weightReminderEnabled ?? false {
                Picker(selection: model.settingsBinding(\.weightReminderHour, default: 8)) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(Self.hourLabel(hour, formatter: model.formatter)).tag(hour)
                    }
                } label: {
                    Text(L("settings.notifications.weightTime")).fixedSize(horizontal: false, vertical: true)
                }
                .pickerStyle(.menu)
                .tint(Color.appAccent)
                .frame(minHeight: Metrics.minimumTapTarget)
                SettingsFootnote(text: L("settings.notifications.weightFooter"))
            }
        } header: {
            Text(L("settings.notifications.section.weight"))
        }
        .listRowBackground(Color.appSurface)
        .disabled(!isEnabled)
    }

    // MARK: - Meal reminders

    private var mealSection: some View {
        Section {
            Toggle(isOn: model.settingsBinding(\.mealReminderEnabled, default: false)) {
                Text(L("settings.notifications.meals")).fixedSize(horizontal: false, vertical: true)
            }
            .tint(Color.appNutrition)
            .frame(minHeight: Metrics.minimumTapTarget)

            if model.settings?.mealReminderEnabled ?? false {
                let hours = model.settings?.mealReminderHours ?? []
                if hours.isEmpty {
                    // A category switched on with nothing scheduled would silently do nothing, so
                    // the empty list gets its own state and its own way out.
                    EmptyStateView(
                        systemImage: "clock.badge.questionmark",
                        title: L("settings.notifications.mealsEmpty.title"),
                        message: L("settings.notifications.mealsEmpty.message")
                    ) {
                        Button(L("settings.notifications.addMealTime")) { addMealHour() }
                            .buttonStyle(SecondaryButtonStyle())
                            .frame(maxWidth: 260)
                    }
                } else {
                    ForEach(hours, id: \.self) { hour in
                        HStack {
                            Picker(selection: mealHourBinding(for: hour)) {
                                ForEach(0..<24, id: \.self) { candidate in
                                    Text(Self.hourLabel(candidate, formatter: model.formatter)).tag(candidate)
                                }
                            } label: {
                                Text(L("settings.notifications.mealTime"))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .pickerStyle(.menu)
                            .tint(Color.appNutrition)

                            Button {
                                removeMealHour(hour)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(Color.appDanger)
                                    .minimumTapTarget()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(L("settings.notifications.removeMealTime",
                                                       Self.hourLabel(hour, formatter: model.formatter))))
                        }
                        .frame(minHeight: Metrics.minimumTapTarget)
                    }

                    if hours.count < 6 {
                        Button {
                            addMealHour()
                        } label: {
                            HStack {
                                Text(L("settings.notifications.addMealTime"))
                                Spacer()
                                Image(systemName: "plus.circle").accessibilityHidden(true)
                            }
                            .frame(minHeight: Metrics.minimumTapTarget)
                        }
                        .foregroundStyle(Color.appNutrition)
                    }
                }
            }
        } header: {
            Text(L("settings.notifications.section.meals"))
        } footer: {
            Text(L("settings.notifications.mealsFooter"))
        }
        .listRowBackground(Color.appSurface)
        .disabled(!isEnabled)
    }

    private func mealHourBinding(for hour: Int) -> Binding<Int> {
        Binding(
            get: { hour },
            set: { newHour in
                var updated = model.settings?.mealReminderHours ?? []
                guard let index = updated.firstIndex(of: hour), !updated.contains(newHour) else { return }
                updated[index] = newHour
                model.updateSettings { $0.mealReminderHours = updated }
            }
        )
    }

    /// Adds the next free hour after the last one, spaced far enough apart to be a different meal.
    private func addMealHour() {
        var updated = model.settings?.mealReminderHours ?? []
        let candidate = updated.max().map { min($0 + 4, 22) } ?? 9
        var hour = candidate
        while updated.contains(hour) && hour < 23 { hour += 1 }
        guard !updated.contains(hour) else { return }
        updated.append(hour)
        model.updateSettings { $0.mealReminderHours = updated }
    }

    private func removeMealHour(_ hour: Int) {
        var updated = model.settings?.mealReminderHours ?? []
        updated.removeAll { $0 == hour }
        model.updateSettings { $0.mealReminderHours = updated }
    }

    // MARK: - Helpers

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private static func date(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }

    /// Formats a bare hour as a time, so a 24-hour locale sees 21:00 and a 12-hour locale 9 PM.
    private static func hourLabel(_ hour: Int, formatter: DisplayFormatter) -> String {
        formatter.time(date(hour: hour, minute: 0))
    }
}

/// Owns permission state and the re-apply cycle, so the view never talks to the notification centre
/// directly and never schedules anything on the main thread's critical path.
@MainActor
@Observable
final class NotificationSettingsViewModel {
    private(set) var status: UNAuthorizationStatus = .notDetermined
    private(set) var isRequesting = false

    @ObservationIgnored private var applyTask: Task<Void, Never>?

    func refresh(service: NotificationService) async {
        await service.refreshAuthorizationStatus()
        status = service.authorizationStatus
    }

    /// Switching reminders on asks iOS once. A refusal leaves the stored flag off, so the interface
    /// never shows reminders as enabled while the system is dropping them.
    func setEnabled(_ isOn: Bool, service: NotificationService, settings: SettingsViewModel) async {
        guard isOn else {
            settings.updateSettings { $0.notificationsEnabled = false }
            return
        }
        isRequesting = true
        if status == .notDetermined {
            _ = await service.requestAuthorization()
        }
        await refresh(service: service)
        isRequesting = false

        let granted = status == .authorized || status == .provisional
        settings.updateSettings { $0.notificationsEnabled = granted }
        if !granted { Haptics.warning() }
    }

    /// Re-applies the whole schedule. Coalesced, because a user dragging a time picker produces a
    /// write per tick and each one would otherwise rebuild every pending request.
    func apply(service: NotificationService, settings: SettingsViewModel) {
        guard let row = settings.settings else { return }
        let weekdays = settings.profile?.availableWeekdays ?? []
        applyTask?.cancel()
        applyTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await service.applySettings(row, weekdays: weekdays)
        }
    }
}

#Preview("Notifications") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            NotificationSettingsView()
        }
    }
}
