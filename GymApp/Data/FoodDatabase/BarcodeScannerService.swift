import AVFoundation
import Foundation

// MARK: - Availability

/// Why the scanner can or cannot run right now.
///
/// The distinction between `notDetermined`, `denied` and `noCamera` matters to the UI: the first
/// warrants a prompt, the second a link to Settings, and the third — the simulator, or a device
/// with no usable back camera — warrants a quiet "type the barcode instead" fallback rather than
/// an error the user cannot act on.
enum BarcodeScannerAvailability: Hashable, Sendable {
    case ready
    case notDetermined
    case denied
    case restricted
    case noCamera
    case failed(String)

    var localizationKey: String {
        switch self {
        case .ready: "food.scanner.ready"
        case .notDetermined: "food.scanner.permissionNeeded"
        case .denied: "food.scanner.permissionDenied"
        case .restricted: "food.scanner.permissionRestricted"
        case .noCamera: "food.scanner.noCamera"
        case .failed: "food.scanner.failed"
        }
    }

    /// Whether the user could still reach a working scanner from here, possibly after a prompt.
    var isRecoverable: Bool {
        switch self {
        case .ready, .notDetermined: true
        case .denied, .restricted, .noCamera, .failed: false
        }
    }

    var isReady: Bool { self == .ready }
}

/// One code read off a packet.
struct DetectedBarcode: Hashable, Sendable {
    /// Digits only, as printed on the packet.
    let value: String
    /// The AVFoundation symbology that produced it, e.g. `"org.gs1.EAN-13"`.
    let symbology: String
    let detectedAt: Date
}

/// Everything that can stop a scan from starting.
enum BarcodeScannerError: LocalizedError, Hashable, Sendable {
    case unavailable(BarcodeScannerAvailability)
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let availability): "The camera is not available: \(availability)."
        case .configurationFailed(let detail): "The camera could not be configured: \(detail)"
        }
    }

    var localizationKey: String {
        switch self {
        case .unavailable(let availability): availability.localizationKey
        case .configurationFailed: "food.scanner.failed"
        }
    }
}

// MARK: - Service

/// A thin, self-contained wrapper around an `AVCaptureSession` that reads food barcodes.
///
/// Design notes worth knowing before changing anything here:
///
/// - **No SwiftUI.** The view layer wraps `previewLayer` in its own representable. Keeping this
///   type UI-framework-free is what lets it be exercised without a view hierarchy.
/// - **Session work never runs on the main thread.** `AVCaptureSession.startRunning()` blocks for
///   a noticeable fraction of a second, so configuration and start/stop are serialised onto a
///   private queue and `start()` simply awaits that queue.
/// - **The simulator has no camera.** Rather than trapping inside AVFoundation, `availability`
///   reports `.noCamera` and `start()` throws, so the scan sheet can fall back to manual entry.
/// - **Codes arrive as an `AsyncStream`.** The metadata delegate fires several times a second for
///   the same packet; debouncing happens here so every consumer gets the same, sane behaviour.
///
/// Mutable state is guarded by a lock and the type is `@unchecked Sendable`: AVFoundation calls
/// back on its own queue, and an actor would force every one of those callbacks through a suspend.
final class BarcodeScannerService: NSObject, @unchecked Sendable {

    /// The symbologies used on food packaging. UPC-A is absent on purpose: AVFoundation reports
    /// it as an EAN-13 with a leading zero, which is also how Open Food Facts stores it.
    static let supportedSymbologies: [AVMetadataObject.ObjectType] = [
        .ean8, .ean13, .upce, .code128,
    ]

    /// Tunables for repeat suppression.
    struct Configuration: Sendable {
        /// The same code is reported at most once per this interval. Two seconds is long enough
        /// that a packet held in frame does not fire repeatedly, and short enough that a user who
        /// deliberately rescans the same item to add a second portion is not left waiting.
        var repeatSuppressionInterval: TimeInterval = 2.0
        /// Floor between any two emissions, so a shelf of packets cannot fire a burst.
        var minimumInterval: TimeInterval = 0.3

        init() {}
    }

    /// The capture session, exposed so a preview layer can be attached to it.
    let session = AVCaptureSession()
    /// Layer the view layer displays. Created up front so the preview can be laid out before the
    /// camera is authorised, which avoids a visible jump when permission is granted.
    let previewLayer: AVCaptureVideoPreviewLayer

    /// Debounced stream of detected codes. Single-consumer by design: the scan sheet is the only
    /// thing that ever reads it, and fanning out would mean deciding what a second consumer should
    /// see for codes emitted before it started listening.
    let codes: AsyncStream<DetectedBarcode>

    private let continuation: AsyncStream<DetectedBarcode>.Continuation
    private let configuration: Configuration
    private let clock: @Sendable () -> Date

    private let sessionQueue = DispatchQueue(label: "com.alejandronewport.forge.barcode.session")
    private let metadataQueue = DispatchQueue(label: "com.alejandronewport.forge.barcode.metadata")

    private let lock = NSLock()
    private var isConfigured = false
    private var lastEmittedValue: String?
    private var lastEmittedAt: Date?
    private var metadataOutput: AVCaptureMetadataOutput?

    init(
        configuration: Configuration = Configuration(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.clock = clock
        self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
        let (stream, continuation) = AsyncStream.makeStream(of: DetectedBarcode.self)
        self.codes = stream
        self.continuation = continuation
        super.init()
        previewLayer.videoGravity = .resizeAspectFill
    }

    deinit {
        continuation.finish()
        if session.isRunning { session.stopRunning() }
    }

    // MARK: Permission

    /// The current state, without prompting.
    var availability: BarcodeScannerAvailability {
        #if targetEnvironment(simulator)
        return .noCamera
        #else
        guard Self.hasCaptureDevice else { return .noCamera }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .ready
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
        #endif
    }

    /// Prompts for camera access if it has not been asked for yet, then reports the outcome.
    ///
    /// Safe to call repeatedly: iOS only ever shows the system prompt once, and every later call
    /// resolves immediately from the stored decision.
    func requestAccess() async -> BarcodeScannerAvailability {
        #if targetEnvironment(simulator)
        return .noCamera
        #else
        guard Self.hasCaptureDevice else { return .noCamera }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .ready
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            return granted ? .ready : .denied
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
        #endif
    }

    private static var hasCaptureDevice: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
            || AVCaptureDevice.default(for: .video) != nil
    }

    // MARK: Lifecycle

    /// Requests access if needed, configures the session once, and starts it.
    ///
    /// Idempotent: calling it while already running is a no-op, which matters because the scan
    /// sheet starts the scanner every time it appears.
    func start() async throws {
        let state = await requestAccess()
        guard state.isReady else { throw BarcodeScannerError.unavailable(state) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                do {
                    try self.configureIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the session. The code stream stays open, so the same instance can be started again.
    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        lock.lock()
        lastEmittedValue = nil
        lastEmittedAt = nil
        lock.unlock()
    }

    /// Stops the session permanently and closes the stream. Call when the scanner is discarded.
    func invalidate() {
        stop()
        continuation.finish()
    }

    /// Restricts detection to a rectangle of the preview, in the preview layer's own coordinates.
    ///
    /// Worth using: narrowing the search band both speeds detection up and stops the scanner
    /// picking up a neighbouring packet's barcode from the edge of the frame.
    func setScanRegion(_ rectInLayerCoordinates: CGRect) {
        let converted = previewLayer.metadataOutputRectConverted(fromLayerRect: rectInLayerCoordinates)
        sessionQueue.async { [weak self] in
            self?.metadataOutput?.rectOfInterest = converted
        }
    }

    /// Turns the torch on or off, for scanning in a dim kitchen or gym. Silently does nothing on
    /// hardware without one.
    func setTorch(_ on: Bool) {
        sessionQueue.async {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  device.hasTorch, device.isTorchAvailable else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
            } catch {
                AppLog.nutrition.error("Torch could not be set: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Configuration

    /// Builds the capture graph. Runs on `sessionQueue`, exactly once.
    private func configureIfNeeded() throws {
        lock.lock()
        let alreadyConfigured = isConfigured
        lock.unlock()
        if alreadyConfigured { return }

        #if targetEnvironment(simulator)
        throw BarcodeScannerError.unavailable(.noCamera)
        #else
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video) else {
            throw BarcodeScannerError.unavailable(.noCamera)
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw BarcodeScannerError.configurationFailed(String(describing: error))
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // `.high` rather than `.photo`: barcode metadata detection does not benefit from full
        // photo resolution, and the lower preset keeps thermals and battery in check.
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }

        guard session.canAddInput(input) else {
            throw BarcodeScannerError.configurationFailed("the camera input was refused")
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            throw BarcodeScannerError.configurationFailed("the metadata output was refused")
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: metadataQueue)
        // Must be set *after* the output joins the session; before that the available types list
        // is empty and the assignment would silently do nothing.
        output.metadataObjectTypes = Self.supportedSymbologies.filter {
            output.availableMetadataObjectTypes.contains($0)
        }

        // Continuous autofocus close to the lens is what makes a small EAN-13 readable at all.
        if device.isFocusModeSupported(.continuousAutoFocus) {
            try? device.lockForConfiguration()
            device.focusMode = .continuousAutoFocus
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            device.unlockForConfiguration()
        }

        lock.lock()
        metadataOutput = output
        isConfigured = true
        lock.unlock()
        #endif
    }

    // MARK: Debouncing

    /// Decides whether a freshly read code should be published.
    ///
    /// Two rules, both about the same problem: the metadata output fires many times a second while
    /// a packet sits in frame. The same value is suppressed for `repeatSuppressionInterval`, and
    /// any emission at all is suppressed for `minimumInterval`.
    private func shouldEmit(_ value: String, at now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let lastEmittedAt, now.timeIntervalSince(lastEmittedAt) < configuration.minimumInterval {
            return false
        }
        if value == lastEmittedValue,
           let lastEmittedAt,
           now.timeIntervalSince(lastEmittedAt) < configuration.repeatSuppressionInterval {
            return false
        }
        lastEmittedValue = value
        lastEmittedAt = now
        return true
    }

    /// Accepts only codes that look like a real GTIN. AVFoundation occasionally reports partial
    /// reads, and a malformed code would just become a wasted network round trip.
    private static func sanitised(_ raw: String, symbology: AVMetadataObject.ObjectType) -> String? {
        if symbology == .code128 {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = trimmed.filter(\.isNumber)
            // Code 128 carries arbitrary text; only accept it when it is in fact a GTIN.
            guard digits.count == trimmed.count, [8, 12, 13, 14].contains(digits.count) else { return nil }
            return digits
        }
        let digits = raw.filter(\.isNumber)
        guard [8, 12, 13, 14].contains(digits.count) else { return nil }
        return digits
    }
}

// MARK: - Metadata delegate

extension BarcodeScannerService: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let now = clock()
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  Self.supportedSymbologies.contains(readable.type),
                  let raw = readable.stringValue,
                  let value = Self.sanitised(raw, symbology: readable.type),
                  shouldEmit(value, at: now) else { continue }

            continuation.yield(
                DetectedBarcode(value: value, symbology: readable.type.rawValue, detectedAt: now)
            )
            // One code per callback: a frame containing two packets should not enqueue both.
            return
        }
    }
}
