import Foundation

public enum ProjectRegistration {
    /// Returns an existing project for the same canonical directory, preserving its identity.
    public static func project(for url: URL, existing: [Project]) throws -> Project {
        guard url.isFileURL else { throw RegistrationError.notDirectory }
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RegistrationError.notDirectory
        }
        if let project = existing.first(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path == canonicalURL.path
        }) {
            return project
        }
        let name = canonicalURL.lastPathComponent.isEmpty ? canonicalURL.path : canonicalURL.lastPathComponent
        return Project(name: name, path: canonicalURL.path)
    }

    public enum RegistrationError: LocalizedError {
        case notDirectory

        public var errorDescription: String? {
            "Escolha uma pasta local existente para cadastrar o projeto."
        }
    }
}
