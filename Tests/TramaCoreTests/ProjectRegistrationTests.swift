import Foundation
import Testing
@testable import TramaCore

struct ProjectRegistrationTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func directoryCreatesNamedProject() throws {
        try withDirectory { directory in
            let projectURL = directory.appendingPathComponent("Meu projeto")
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
            let project = try ProjectRegistration.project(for: projectURL, existing: [])
            #expect(project.name == "Meu projeto")
            #expect(project.path == projectURL.standardizedFileURL.resolvingSymlinksInPath().path)
        }
    }

    @Test func missingDirectoryIsRejected() throws {
        try withDirectory { directory in
            #expect(throws: ProjectRegistration.RegistrationError.self) {
                try ProjectRegistration.project(for: directory.appendingPathComponent("missing"), existing: [])
            }
        }
    }

    @Test func regularFileIsRejected() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("README.md")
            try Data("hello".utf8).write(to: file)
            #expect(throws: ProjectRegistration.RegistrationError.self) {
                try ProjectRegistration.project(for: file, existing: [])
            }
        }
    }

    @Test func symlinkReusesExistingIdentityAndName() throws {
        try withDirectory { directory in
            let target = directory.appendingPathComponent("project")
            let alias = directory.appendingPathComponent("alias")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
            var original = try ProjectRegistration.project(for: target, existing: [])
            original.name = "Nome personalizado"
            let duplicate = try ProjectRegistration.project(for: alias, existing: [original])
            #expect(duplicate == original)
        }
    }

    @Test func remoteURLIsRejected() throws {
        let url = try #require(URL(string: "https://example.com/project"))
        #expect(throws: ProjectRegistration.RegistrationError.self) {
            try ProjectRegistration.project(for: url, existing: [])
        }
    }
}
