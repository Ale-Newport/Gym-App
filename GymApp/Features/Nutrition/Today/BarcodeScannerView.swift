import AVFoundation
import SwiftData
import SwiftUI

// MARK: - Outcome

/// What the scan sheet hands back to the flow that presented it.
///
/// A scanned product travels as a value rather than as a stored row: the user still has the portion
/// editor to get through, and a barcode somebody pointed a camera at is not yet a food they logged.
enum BarcodeScanOutcome: Hashable, Sendable {
    case cancelled
    /// A product one of the providers recognised. Nothing has been written to the store yet.
    case found(FoodSearchResult)
    /// A food the user already has, matched on its barcode.
    case foundStored(UUID)
    /// A code nothing recognised, handed back so the caller can seed a hand-written food with it.
    case notFound(String)
}

// MARK: - View model

/// Drives one scanning session: camera lifecycle, the debounced code stream, and the lookup.
///
/// The camera is stopped the moment a code resolves. A scanner that keeps running behind a result
/// screen costs battery, heats the phone and — because the same packet is usually still in frame —
/// invites a second detection nobody asked for.
@MainActor
@Observable
final class BarcodeScannerViewModel {

    /// A resolved product, together with the outcome that logging it produces.
    struct Match: Equatable {
        let barcode: String
        let name: String
        let brand: String?
        let macrosPer100: MacroNutrients
        let basisUnit: ServingUnit
        /// True when the match came from the user's own foods rather than from a provider.
        let isStored: Bool
        let outcome: BarcodeScanOutcome
    }

    enum Phase: Equatable {
        case preparing
        case scanning
        /// A code has been read and is being looked up. `fromCamera` decides whether the camera
        /// stays on screen underneath the progress, or whether the manual form does.
        case lookingUp(barcode: String, fromCamera: Bool)
        case matched(Match)
        /// `wasDegraded` is true when a provider failed rather than genuinely having no record,
        /// so the screen can say "not checked" instead of implying the product does not exist.
        case notFound(barcode: String, wasDegraded: Bool)
        case unavailable(BarcodeScannerAvailability)
        case manualEntry
    }

    private(set) var phase: Phase = .preparing
    private(set) var isTorchOn = false
    /// False on the simulator, on hardware without a usable camera, and whenever access is refused.
    /// Everything that would otherwise dead-end falls back to typing the digits instead.
    private(set) var isCameraAvailable = false

    var manualCode: String = ""

    let service = BarcodeScannerService()

    private let repository: NutritionRepository
    private var scanRegion: CGRect = .zero

    init(context: ModelContext) {
        self.repository = NutritionRepository(context: context)
    }

    deinit {
        service.invalidate()
    }

    // MARK: Lifecycle

    /// Starts the camera and consumes codes until the surrounding task is cancelled.
    func run() async {
        let availability = await service.requestAccess()
        guard availability.isReady else {
            AppLog.nutrition.info("Barcode scanner unavailable: \(availability.localizationKey, privacy: .public)")
            isCameraAvailable = false
            phase = .unavailable(availability)
            return
        }

        do {
            try await service.start()
        } catch {
            AppLog.nutrition.error("Barcode scanner could not start: \(String(describing: error), privacy: .public)")
            isCameraAvailable = false
            phase = .unavailable(Self.availability(from: error))
            return
        }

        isCameraAvailable = true
        if phase == .preparing { phase = .scanning }
        applyScanRegion()

        for await code in service.codes {
            guard phase == .scanning else { continue }
            handleDetection(code)
            await lookUp(code.value, fromCamera: true)
        }
    }

    /// Restarts a session that was stopped after a result. Idempotent, like `start()` itself.
    func scanAgain() async {
        guard isCameraAvailable else {
            beginManualEntry()
            return
        }
        manualCode = ""
        phase = .preparing
        do {
            try await service.start()
            phase = .scanning
            applyScanRegion()
        } catch {
            AppLog.nutrition.error("Barcode scanner could not restart: \(String(describing: error), privacy: .public)")
            isCameraAvailable = false
            phase = .unavailable(Self.availability(from: error))
        }
    }

    /// Resumes after the app comes back to the foreground, where iOS has suspended the session.
    func resumeIfScanning() async {
        guard isCameraAvailable, phase == .scanning else { return }
        try? await service.start()
        applyScanRegion()
    }

    /// Stops the camera and the torch. Called when the sheet goes away.
    func stop() {
        if isTorchOn {
            service.setTorch(false)
            isTorchOn = false
        }
        service.stop()
    }

    // MARK: Camera controls

    func toggleTorch() {
        isTorchOn.toggle()
        service.setTorch(isTorchOn)
        Haptics.tap()
    }

    /// Narrows detection to the frame drawn on screen, so a neighbouring packet on a shelf cannot
    /// be read from the edge of the picture.
    func setScanRegion(_ rect: CGRect) {
        guard rect != scanRegion else { return }
        scanRegion = rect
        applyScanRegion()
    }

    private func applyScanRegion() {
        guard scanRegion.width > 0, scanRegion.height > 0 else { return }
        service.setScanRegion(scanRegion)
    }

    // MARK: Manual entry

    var sanitisedManualCode: String { manualCode.filter(\.isNumber) }

    /// GTINs are 8, 12, 13 or 14 digits. Anything else is a typo, and looking it up would only
    /// spend a network round trip to say so.
    var isManualCodeValid: Bool { [8, 12, 13, 14].contains(sanitisedManualCode.count) }

    func beginManualEntry() {
        stop()
        phase = .manualEntry
    }

    func submitManualCode() async {
        guard isManualCodeValid else { return }
        Haptics.tap()
        await lookUp(sanitisedManualCode, fromCamera: false)
    }

    // MARK: Detection and lookup

    /// The moment a code is read: a haptic and a state change, before any lookup latency.
    private func handleDetection(_ code: DetectedBarcode) {
        Haptics.tap()
        phase = .lookingUp(barcode: code.value, fromCamera: true)
        stop()
    }

    /// Own foods first, then the providers. A food the user has already created and corrected
    /// should always win over a crowd-sourced record of the same packet.
    private func lookUp(_ barcode: String, fromCamera: Bool) async {
        let code = barcode.filter(\.isNumber)
        guard !code.isEmpty else { return }
        phase = .lookingUp(barcode: code, fromCamera: fromCamera)

        if let stored = try? repository.food(barcode: code) {
            Haptics.success()
            phase = .matched(
                Match(
                    barcode: stored.barcode ?? code,
                    name: stored.name,
                    brand: stored.brand,
                    macrosPer100: stored.macrosPer100,
                    basisUnit: stored.basisUnit,
                    isStored: true,
                    outcome: .foundStored(stored.id)
                )
            )
            return
        }

        let (result, failures) = await NutritionProviders.online.food(withBarcode: code)
        guard !Task.isCancelled else { return }

        if let result {
            Haptics.success()
            phase = .matched(
                Match(
                    barcode: result.barcode ?? code,
                    name: result.name,
                    brand: result.brand,
                    macrosPer100: result.macrosPer100,
                    basisUnit: result.basisUnit,
                    isStored: false,
                    outcome: .found(result)
                )
            )
        } else {
            Haptics.warning()
            if let failure = failures.values.first {
                AppLog.nutrition.info("Barcode lookup degraded: \(failure.localizationKey, privacy: .public)")
            }
            phase = .notFound(barcode: code, wasDegraded: !failures.isEmpty)
        }
    }

    private static func availability(from error: any Error) -> BarcodeScannerAvailability {
        switch error as? BarcodeScannerError {
        case .unavailable(let availability): availability
        case .configurationFailed(let detail): .failed(detail)
        case nil: .failed(String(describing: error))
        }
    }
}

// MARK: - View

/// Scanning a barcode off a packet, and everything that happens when that does not work.
///
/// The screen has four jobs and treats them as equals: read a code, say plainly why it cannot, let
/// the digits be typed instead, and hand whatever it found back to the add-food flow. Nothing here
/// is allowed to end in a shrug — every state carries a way forward, including the simulator, an
/// iPad without a camera and a user who has refused access.
struct BarcodeScannerView: View {
    let onFinish: (BarcodeScanOutcome) -> Void

    @State private var model: BarcodeScannerViewModel?
    @FocusState private var isCodeFieldFocused: Bool

    @Environment(\.modelContext) private var context
    @Environment(\.displayFormatter) private var formatter
    @Environment(\.scenePhase) private var scenePhase

    init(onFinish: @escaping (BarcodeScanOutcome) -> Void) {
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    LoadingStateView(message: L("common.loading"))
                }
            }
            .background(Color.appBackground)
            .navigationTitle(L("food.scanner.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.appSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { onFinish(.cancelled) }
                }
                if let model, isShowingCamera(model) {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.toggleTorch()
                        } label: {
                            Image(systemName: model.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        }
                        .accessibilityLabel(L("food.scanner.torch"))
                        .accessibilityAddTraits(model.isTorchOn ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
        }
        // The sheet is presented by the add-food flow, so the height is asked for from in here.
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task {
            let created = model ?? BarcodeScannerViewModel(context: context)
            if model == nil { model = created }
            await created.run()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, let model else { return }
            Task { await model.resumeIfScanning() }
        }
        .onDisappear { model?.stop() }
    }

    // MARK: Routing

    @ViewBuilder
    private func content(_ model: BarcodeScannerViewModel) -> some View {
        switch model.phase {
        case .preparing, .scanning:
            camera(model, detectedCode: nil)
        case .lookingUp(let barcode, let fromCamera):
            if fromCamera {
                camera(model, detectedCode: barcode)
            } else {
                LoadingStateView(message: L("nutritionLog.scanner.lookingUp", barcode))
            }
        case .matched(let match):
            matched(model, match: match)
        case .notFound(let barcode, let wasDegraded):
            notFound(model, barcode: barcode, wasDegraded: wasDegraded)
        case .unavailable(let availability):
            unavailable(model, availability: availability)
        case .manualEntry:
            manualEntry(model)
        }
    }

    private func isShowingCamera(_ model: BarcodeScannerViewModel) -> Bool {
        switch model.phase {
        case .preparing, .scanning: true
        case .lookingUp(_, let fromCamera): fromCamera
        default: false
        }
    }

    // MARK: Camera

    private func camera(_ model: BarcodeScannerViewModel, detectedCode: String?) -> some View {
        ZStack {
            GeometryReader { geometry in
                let window = scanWindow(in: geometry.size)

                ZStack(alignment: .topLeading) {
                    CameraPreview(previewLayer: model.service.previewLayer)
                        .accessibilityElement()
                        .accessibilityLabel(L("nutritionLog.a11y.scannerViewfinder"))

                    ScanWindowMask(window: window)
                        .fill(Color.appBackground.opacity(0.62), style: FillStyle(eoFill: true))
                        .accessibilityHidden(true)

                    RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                        .strokeBorder(detectedCode == nil ? Color.appNutrition : Color.appSuccess, lineWidth: 3)
                        .frame(width: window.width, height: window.height)
                        .position(x: window.midX, y: window.midY)
                        .animation(.easeOut(duration: 0.2), value: detectedCode)
                        .accessibilityHidden(true)
                }
                .onAppear { model.setScanRegion(window) }
                .onChange(of: window) { _, newWindow in model.setScanRegion(newWindow) }
            }
            .ignoresSafeArea()

            VStack(spacing: Metrics.spacing12) {
                Spacer(minLength: Metrics.spacing24)
                statusCard(detectedCode: detectedCode)
                // Hidden mid-lookup: switching to the form while a result is on its way would put
                // the user in one screen and the answer in another.
                if detectedCode == nil {
                    Button {
                        model.beginManualEntry()
                    } label: {
                        Label(L("food.scanner.manualEntry"), systemImage: "keyboard")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .screenPadding()
            .padding(.bottom, Metrics.spacing20)
            .readableWidth()
        }
    }

    /// The instructions, and — once a code is read — the confirmation that it was.
    private func statusCard(detectedCode: String?) -> some View {
        Card {
            if let detectedCode {
                HStack(spacing: Metrics.spacing12) {
                    ProgressView()
                    Text(L("nutritionLog.scanner.lookingUp", detectedCode))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: Metrics.spacing4) {
                    Text(L("food.scanner.ready"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("food.scanner.hint"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// A wide, shallow window: barcodes are wider than they are tall, and a band rather than a box
    /// is what stops the reader picking up the packet next to the one being held.
    private func scanWindow(in size: CGSize) -> CGRect {
        let width = min(size.width - Metrics.screenPadding * 2, 420)
        let height = min(max(width * 0.52, 140), max(size.height * 0.36, 140))
        let x = (size.width - width) / 2
        let y = max((size.height - height) / 2 - Metrics.spacing40, Metrics.spacing40)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: Result states

    private func matched(_ model: BarcodeScannerViewModel, match: BarcodeScannerViewModel.Match) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                Text(L("nutritionLog.scanner.foundTitle"))
                    .font(.appOverline)
                    .foregroundStyle(Color.appTextSecondary)
                    .accessibilityAddTraits(.isHeader)

                Card {
                    VStack(alignment: .leading, spacing: Metrics.spacing8) {
                        Text(match.name)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let brand = match.brand, !brand.isEmpty {
                            Text(brand)
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: Metrics.spacing8) {
                            Chip(title: match.barcode, systemImage: "barcode", tint: .appTextSecondary)
                            if match.isStored {
                                Chip(
                                    title: L("nutritionLog.scanner.matchedStored"),
                                    systemImage: "checkmark.circle",
                                    tint: .appNutrition
                                )
                            }
                        }
                        Divider().overlay(Color.appSeparator)
                        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                            Text(match.basisUnit == .milliliters ? L("food.result.per100ml") : L("food.result.per100g"))
                                .font(.footnote)
                                .foregroundStyle(Color.appTextSecondary)
                            Spacer(minLength: Metrics.spacing8)
                            Text(formatter.energy(match.macrosPer100.kilocalories))
                                .font(.appNumeric(20))
                                .foregroundStyle(Color.appNutrition)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        MacroSummaryLine(macros: match.macrosPer100)
                    }
                }

                Button {
                    Haptics.tap()
                    onFinish(match.outcome)
                } label: {
                    Text(L("nutritionLog.action.addToMeal"))
                }
                .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))

                againButton(model)
            }
            .screenPadding()
            .padding(.vertical, Metrics.spacing20)
            .readableWidth()
        }
    }

    private func notFound(_ model: BarcodeScannerViewModel, barcode: String, wasDegraded: Bool) -> some View {
        ScrollView {
            EmptyStateView(
                systemImage: "barcode.viewfinder",
                title: wasDegraded ? L("nutritionLog.scanner.notCheckedTitle") : L("food.scanner.notFound"),
                message: L("nutritionLog.scanner.createMessage")
            ) {
                VStack(spacing: Metrics.spacing12) {
                    Chip(title: barcode, systemImage: "barcode", tint: .appTextSecondary)
                    if wasDegraded {
                        ExplanationNote(
                            text: L("nutritionLog.scanner.offlineNote"),
                            systemImage: "wifi.slash",
                            tint: .appWarning
                        )
                    }
                    Button {
                        Haptics.tap()
                        onFinish(.notFound(barcode))
                    } label: {
                        Text(L("nutritionLog.scanner.createFood"))
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
                    againButton(model)
                }
                .frame(maxWidth: 340)
            }
            .padding(.vertical, Metrics.spacing20)
            .readableWidth()
        }
    }

    private func unavailable(_ model: BarcodeScannerViewModel, availability: BarcodeScannerAvailability) -> some View {
        ScrollView {
            EmptyStateView(
                systemImage: availability == .noCamera ? "camera.metering.unknown" : "video.slash",
                title: L("nutritionLog.scanner.unavailableTitle"),
                message: L(availability.localizationKey)
            ) {
                VStack(spacing: Metrics.spacing12) {
                    // Only a refusal is fixable in Settings. Restricted hardware and a missing
                    // camera are not, so those go straight to typing the digits.
                    if availability == .denied {
                        Button {
                            openSystemSettings()
                        } label: {
                            Label(L("nutritionLog.scanner.openSettings"), systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
                        Button {
                            model.beginManualEntry()
                        } label: {
                            Label(L("food.scanner.manualEntry"), systemImage: "keyboard")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button {
                            model.beginManualEntry()
                        } label: {
                            Label(L("food.scanner.manualEntry"), systemImage: "keyboard")
                        }
                        .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
                    }
                }
                .frame(maxWidth: 340)
            }
            .padding(.vertical, Metrics.spacing20)
            .readableWidth()
        }
    }

    // MARK: Manual entry

    private func manualEntry(_ model: BarcodeScannerViewModel) -> some View {
        @Bindable var model = model

        return ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                Card {
                    VStack(alignment: .leading, spacing: Metrics.spacing12) {
                        Text(L("nutritionLog.scanner.manualTitle"))
                            .font(.appOverline)
                            .foregroundStyle(Color.appTextSecondary)
                        Text(L("nutritionLog.scanner.manualMessage"))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField(L("nutritionLog.scanner.manualPlaceholder"), text: $model.manualCode)
                            .keyboardType(.numberPad)
                            .font(.appNumeric(20))
                            .foregroundStyle(Color.appTextPrimary)
                            .padding(.horizontal, Metrics.spacing12)
                            .frame(minHeight: Metrics.gymTapTarget)
                            .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
                            .focused($isCodeFieldFocused)
                            .submitLabel(.search)
                            .onSubmit { Task { await model.submitManualCode() } }
                            .accessibilityLabel(L("nutritionLog.scanner.manualTitle"))
                        Text(L("nutritionLog.scanner.manualHint"))
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button {
                    Task { await model.submitManualCode() }
                } label: {
                    Text(L("nutritionLog.scanner.lookUp"))
                }
                .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
                .disabled(!model.isManualCodeValid)

                if model.isCameraAvailable {
                    Button {
                        Task { await model.scanAgain() }
                    } label: {
                        Label(L("nutritionLog.scanner.scanAgain"), systemImage: "barcode.viewfinder")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .screenPadding()
            .padding(.vertical, Metrics.spacing20)
            .readableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { isCodeFieldFocused = true }
    }

    // MARK: Shared pieces

    /// "Scan another" where there is a camera, "Enter barcode" where there is not — so no result
    /// screen is ever the end of the road.
    @ViewBuilder
    private func againButton(_ model: BarcodeScannerViewModel) -> some View {
        if model.isCameraAvailable {
            Button {
                Task { await model.scanAgain() }
            } label: {
                Label(L("nutritionLog.scanner.scanAgain"), systemImage: "barcode.viewfinder")
            }
            .buttonStyle(SecondaryButtonStyle())
        } else {
            Button {
                model.beginManualEntry()
            } label: {
                Label(L("food.scanner.manualEntry"), systemImage: "keyboard")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Scan window

/// The dimming layer with a hole in it. Even-odd filling gives the cut-out without blend modes,
/// which keeps the whole overlay a single, cheap shape.
private struct ScanWindowMask: Shape {
    let window: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addPath(Path(roundedRect: window, cornerRadius: Metrics.cornerLarge, style: .continuous))
        return path
    }
}

// MARK: - Camera preview

/// Hosts the capture session's preview layer. Deliberately dumb: the session is owned by the
/// service, and this view only gives its layer somewhere to live and a frame to fill.
private struct CameraPreview: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> CameraPreviewContainer {
        let view = CameraPreviewContainer()
        view.isAccessibilityElement = false
        view.attach(previewLayer)
        return view
    }

    func updateUIView(_ view: CameraPreviewContainer, context: Context) {
        view.attach(previewLayer)
    }

    static func dismantleUIView(_ view: CameraPreviewContainer, coordinator: ()) {
        view.detach()
    }
}

private final class CameraPreviewContainer: UIView {
    private weak var attachedLayer: AVCaptureVideoPreviewLayer?

    func attach(_ previewLayer: AVCaptureVideoPreviewLayer) {
        guard previewLayer !== attachedLayer else { return }
        attachedLayer?.removeFromSuperlayer()
        layer.addSublayer(previewLayer)
        attachedLayer = previewLayer
        setNeedsLayout()
    }

    func detach() {
        attachedLayer?.removeFromSuperlayer()
        attachedLayer = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The implicit layer animation would otherwise slide the picture on every layout pass.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attachedLayer?.frame = bounds
        CATransaction.commit()
    }
}

#Preview("Barcode scanner") {
    PreviewHost(scenario: .emptyNutritionDay) {
        BarcodeScannerView { _ in }
    }
}
