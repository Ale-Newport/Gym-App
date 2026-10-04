import Foundation

/// Supplies the artwork for an exercise.
///
/// The media that ships with the app is its own: 3D renders of one original athlete, produced by the
/// Gym avatar project and imported by `Tools/prepare_dataset.py`. It is **not** covered by the
/// dataset's MIT licence (see `docs/LICENSES.md`). This protocol keeps the source replaceable:
/// another set of artwork means one new conformance and one line in `AppEnvironment`, with no
/// change to any view, engine or model.
protocol ExerciseMediaProviding: Sendable {
    /// Still image used in lists and grids. Cheap to load.
    func thumbnailURL(for exercise: Exercise) -> URL?
    /// Looping animation used on detail and workout screens.
    func animationURL(for exercise: Exercise) -> URL?
    /// Copyright line that must be displayed wherever this provider's media appears, if its terms
    /// require one. Every media credit in the interface hides itself when this is `nil`.
    var attribution: String? { get }
    /// Link shown next to the attribution, when the rights holder requires one.
    var attributionURL: URL? { get }
}

/// Serves the media bundled under `Resources/ExerciseMedia`: a 240×240 JPEG thumbnail and a
/// 400×400 animated WebP per exercise, named after the exercise id.
///
/// The artwork is the app's own, so by default it carries no credit line.
struct BundledExerciseMediaProvider: ExerciseMediaProviding {
    private let thumbnailRoot: URL?
    private let animationRoot: URL?

    let attribution: String?
    let attributionURL: URL?

    init(
        bundle: Bundle = .main,
        attribution: String? = nil,
        attributionURL: URL? = nil
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
