import Foundation

/// Supplies the artwork for an exercise.
///
/// The media that ships with the app is © Gym visual and is **not** covered by the dataset's MIT
/// licence (see `docs/LICENSES.md`). This protocol is the seam that keeps that dependency
/// replaceable: swapping in self-produced artwork means writing one new conformance and changing
/// one line in `AppEnvironment`, with no change to any view, engine or model.
protocol ExerciseMediaProviding: Sendable {
    /// Still image used in lists and grids. Cheap to load.
    func thumbnailURL(for exercise: Exercise) -> URL?
    /// Looping animation used on detail and workout screens.
    func animationURL(for exercise: Exercise) -> URL?
    /// Copyright line that must be displayed wherever this provider's media appears.
    var attribution: String? { get }
    /// Link shown next to the attribution, when the rights holder requires one.
    var attributionURL: URL? { get }
}

/// Serves the 180×180 media bundled under `Resources/ExerciseMedia`.
///
/// The files keep their original names and resolution, and the attribution travels with them, as
/// the rights holder's terms require.
struct BundledExerciseMediaProvider: ExerciseMediaProviding {
    private let thumbnailRoot: URL?
    private let animationRoot: URL?

    let attribution: String?
    let attributionURL: URL?

    init(
        bundle: Bundle = .main,
        attribution: String? = "© Gym visual — https://gymvisual.com/",
        attributionURL: URL? = URL(string: "https://gymvisual.com/")
    ) {
        let mediaRoot = bundle.url(forResource: "ExerciseMedia", withExtension: nil)
        self.thumbnailRoot = mediaRoot?.appendingPathComponent("thumbnails", isDirectory: true)
        self.animationRoot = mediaRoot?.appendingPathComponent("animations", isDirectory: true)
        self.attribution = attribution
        self.attributionURL = attributionURL
    }

    func thumbnailURL(for exercise: Exercise) -> URL? {
        guard let thumbnailRoot else { return nil }
        let url = thumbnailRoot.appendingPathComponent(exercise.thumbnailFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func animationURL(for exercise: Exercise) -> URL? {
        guard let animationRoot else { return nil }
        let url = animationRoot.appendingPathComponent(exercise.animationFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// A provider that returns nothing. Used in unit tests and as a safe fallback when the media
/// directory has been removed from the bundle — the app stays fully usable without artwork.
struct EmptyExerciseMediaProvider: ExerciseMediaProviding {
    func thumbnailURL(for exercise: Exercise) -> URL? { nil }
    func animationURL(for exercise: Exercise) -> URL? { nil }
    var attribution: String? { nil }
    var attributionURL: URL? { nil }
}
