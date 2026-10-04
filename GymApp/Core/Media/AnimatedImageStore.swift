import Foundation
import ImageIO
import UIKit

/// Decoded frames of one animation, ready to hand to `UIImageView`.
struct DecodedAnimation: Sendable {
    let frames: [UIImage]
    let duration: TimeInterval
    /// Approximate resident bytes, used as the cache cost.
    let byteCost: Int
}

/// Decodes and caches exercise animations.
///
/// There are 500 animations in the bundle, 400×400 animated WebP of up to 36 frames. One expands to
/// about 8 MB on average (23 MB at most) once its frames are decoded to bitmaps, so decoding them
/// eagerly — or caching them without a ceiling — would exhaust memory almost immediately. This
/// store therefore:
///
/// * decodes lazily, off the main thread, and only for the animation actually on screen;
/// * caches a small number of recent animations under a hard byte ceiling (`NSCache` evicts by
///   cost, and also evicts automatically when the system reports memory pressure);
/// * coalesces concurrent requests for the same file so a fast scroll decodes each animation once;
/// * caps decoded frames per animation, so a pathological file cannot blow the budget.
///
/// Lists never touch this store — they use the 5 KB JPEG thumbnails through `ThumbnailStore`.
actor AnimatedImageStore {
    static let shared = AnimatedImageStore()

    private let cache = NSCache<NSString, CacheBox>()
    private var inFlight: [String: Task<DecodedAnimation?, Never>] = [:]

    /// Hard ceiling on decoded animation bytes. Roughly six average animations.
    private static let byteLimit = 48 * 1024 * 1024
    /// Beyond this many frames the animation is sub-sampled; real files sit far below it.
    private static let maximumFrames = 60

    private final class CacheBox {
        let animation: DecodedAnimation
        init(_ animation: DecodedAnimation) { self.animation = animation }
    }

    init() {
        cache.totalCostLimit = Self.byteLimit
        cache.countLimit = 14
    }

    /// Returns the decoded animation at `url`, decoding it if necessary.
    func animation(at url: URL) async -> DecodedAnimation? {
        let key = url.path
        if let cached = cache.object(forKey: key as NSString) { return cached.animation }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task.detached(priority: .userInitiated) { Self.decode(url: url) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        if let result {
            cache.setObject(CacheBox(result), forKey: key as NSString, cost: result.byteCost)
        }
        return result
    }

    /// Decodes ahead of time so the next exercise in a workout appears instantly.
    func prefetch(_ urls: [URL]) {
        for url in urls.prefix(3) where cache.object(forKey: url.path as NSString) == nil {
            Task { _ = await animation(at: url) }
        }
    }

    /// Drops every decoded animation. Called on memory warnings and when leaving a workout.
    func purge() {
        cache.removeAllObjects()
    }

    // MARK: - Decoding

    private nonisolated static func decode(url: URL) -> DecodedAnimation? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: false,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            AppLog.media.error("Could not open animation at \(url.lastPathComponent, privacy: .public)")
            return nil
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { return nil }

        // Sub-sample if a file is unexpectedly long, keeping playback duration intact.
        let stride = max(1, Int((Double(frameCount) / Double(maximumFrames)).rounded(.up)))

        var frames: [UIImage] = []
        var totalDuration: TimeInterval = 0
        var byteCost = 0
        frames.reserveCapacity(min(frameCount, maximumFrames))

        var index = 0
        while index < frameCount {
            autoreleasepool {
                if let cgImage = CGImageSourceCreateImageAtIndex(source, index, options as CFDictionary) {
                    frames.append(UIImage(cgImage: cgImage))
                    byteCost += cgImage.height * cgImage.bytesPerRow
                }
                var delay = frameDelay(source: source, index: index)
                if stride > 1 {
                    // Absorb the delay of the frames being skipped so timing stays correct.
                    for skipped in (index + 1)..<min(index + stride, frameCount) {
                        delay += frameDelay(source: source, index: skipped)
                    }
                }
                totalDuration += delay
            }
            index += stride
        }

        guard !frames.isEmpty else { return nil }
        // Guard against files that declare zero delays.
        let duration = totalDuration > 0.01 ? totalDuration : Double(frames.count) / 15.0
        return DecodedAnimation(frames: frames, duration: duration, byteCost: max(byteCost, 1))
    }

    /// Frame delay of an animated WebP or GIF, honouring the browser convention that delays below
    /// 20 ms mean 100 ms.
    private nonisolated static func frameDelay(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.1
        }
        let delay: Double?
        if let webP = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            delay = webP[kCGImagePropertyWebPUnclampedDelayTime] as? Double
                ?? webP[kCGImagePropertyWebPDelayTime] as? Double
        } else if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            delay = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif[kCGImagePropertyGIFDelayTime] as? Double
        } else {
            delay = nil
        }
        guard let delay, delay >= 0.02 else { return 0.1 }
        return delay
    }
}

/// Caches the small still thumbnails used in lists.
///
/// These are 240×240 JPEGs averaging 5 KB, so a generous cache is still tiny; the win is avoiding
/// repeated file I/O and JPEG decode while scrolling 500 rows.
actor ThumbnailStore {
    static let shared = ThumbnailStore()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        cache.countLimit = 600
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func image(at url: URL) async -> UIImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if let existing = inFlight[url.path] { return await existing.value }

        let task = Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let image = UIImage(data: data)?.preparingForDisplay() else { return nil }
            return image
        }
        inFlight[url.path] = task
        let image = await task.value
        inFlight[url.path] = nil

        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    func purge() { cache.removeAllObjects() }
}
