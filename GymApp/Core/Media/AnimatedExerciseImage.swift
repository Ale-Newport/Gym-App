import SwiftUI
import UIKit

/// Plays an exercise animation, looping, at whatever size it is given.
///
/// Backed by `UIImageView`'s native frame animation rather than a SwiftUI `TimelineView`: UIKit
/// drives the frames on the render server, so a looping animation costs no SwiftUI invalidations
/// and does not compete with set logging for main-thread time.
struct AnimatedExerciseImage: View {
    let url: URL?
    /// Still image shown while the animation decodes, so the layout never jumps.
    var placeholderURL: URL?
    var isPlaying: Bool = true

    @State private var animation: DecodedAnimation?
    @State private var placeholder: UIImage?
    @State private var didFail = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let animation, !reduceMotion {
                AnimatedFrameView(frames: animation.frames, duration: animation.duration, isPlaying: isPlaying)
                    .transition(.opacity)
            } else if let still = animation?.frames.first ?? placeholder {
                Image(uiImage: still)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if didFail {
                MediaUnavailableView()
            } else {
                Rectangle()
                    .fill(Color.appFillSecondary)
                    .overlay(ProgressView())
            }
        }
        .animation(.easeInOut(duration: 0.2), value: animation != nil)
        .task(id: url) { await load() }
    }

    private func load() async {
        animation = nil
        didFail = false

        if let placeholderURL {
            placeholder = await ThumbnailStore.shared.image(at: placeholderURL)
        }
        guard let url else {
            didFail = placeholder == nil
            return
        }
        let decoded = await AnimatedImageStore.shared.animation(at: url)
        animation = decoded
        didFail = decoded == nil && placeholder == nil
    }
}

/// Thin `UIImageView` wrapper that owns the frame animation.
private struct AnimatedFrameView: UIViewRepresentable {
    let frames: [UIImage]
    let duration: TimeInterval
    let isPlaying: Bool

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        if view.animationImages?.count != frames.count || view.image !== frames.first {
            view.image = frames.first
            view.animationImages = frames
            view.animationDuration = duration
            view.animationRepeatCount = 0
        }
        if isPlaying {
            if !view.isAnimating { view.startAnimating() }
        } else if view.isAnimating {
            view.stopAnimating()
        }
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: ()) {
        view.stopAnimating()
        view.animationImages = nil
    }
}

/// The small still image used in lists and grids.
struct ExerciseThumbnail: View {
    let url: URL?
    var cornerRadius: CGFloat = 10

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.appFillSecondary
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            } else {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.appTextTertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await ThumbnailStore.shared.image(at: url)
        }
    }
}

/// Shown when artwork is missing — for example after the media directory has been swapped out.
struct MediaUnavailableView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 28, weight: .light))
            Text(L("media.unavailable"))
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Color.appTextTertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appFillSecondary)
    }
}

/// The mandatory media credit. Rendered wherever bundled artwork is shown.
struct MediaAttributionLabel: View {
    let attribution: String?
    var url: URL?

    var body: some View {
        if let attribution, !attribution.isEmpty {
            Group {
                if let url {
                    Link(destination: url) {
                        Text(attribution).underline()
                    }
                } else {
                    Text(attribution)
                }
            }
            .font(.caption2)
            .foregroundStyle(Color.appTextTertiary)
            .accessibilityLabel(Text(attribution))
        }
    }
}
