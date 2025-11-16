import Foundation

public enum ZenzCoreMLResources {
    /// Bundle that contains the embedded Core ML assets.
    public static var bundle: Bundle {
        Bundle.module
    }

    /// Location of the stateful Core ML models directory.
    public static var statefulModelsDirectory: URL? {
        bundle.resourceURL?.appendingPathComponent("Stateful", isDirectory: true)
    }

    /// Convenience helper to fetch a particular `.mlpackage` inside the stateful directory.
    public static func statefulModelURL(named name: String) -> URL? {
        bundle.url(forResource: name, withExtension: "mlpackage", subdirectory: "Stateful")
    }
}
