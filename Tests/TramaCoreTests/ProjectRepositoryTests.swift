import Foundation
import Testing
@testable import TramaCore

struct ProjectRepositoryTests {
    private func withStore(_ body: (ProjectRepository) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(ProjectRepository(fileURL: directory.appendingPathComponent("nested/projects.json")))
    }

    @Test func missingStoreStartsEmpty() throws {
        try withStore { repository in
            let loaded = try repository.load()
            #expect(loaded.isEmpty)
        }
    }

    @Test func projectsSurviveRepositoryRecreation() throws {
        try withStore { repository in
            let projects = [Project(name: "Projeto com acentuação", path: "/tmp/meu projeto")]
            try repository.save(projects)
            let reopened = ProjectRepository(fileURL: repository.fileURL)
            #expect(try reopened.load() == projects)
            try reopened.save([])
            let loaded = try repository.load()
            #expect(loaded.isEmpty)
        }
    }

    @Test func corruptStoreIsReportedAndPreserved() throws {
        try withStore { repository in
            try repository.save([])
            let corrupt = Data("not valid json".utf8)
            try corrupt.write(to: repository.fileURL)
            #expect(throws: (any Error).self) { try repository.load() }
            #expect(try Data(contentsOf: repository.fileURL) == corrupt)
        }
    }

    @Test func futureSchemaIsRejected() throws {
        try withStore { repository in
            try repository.save([])
            try Data(#"{"version":2,"projects":[]}"#.utf8).write(to: repository.fileURL)
            #expect(throws: ProjectRepository.RepositoryError.self) { try repository.load() }
        }
    }

    @Test func writeFailureIsReported() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("a file cannot be a parent directory".utf8).write(to: directory)
        let repository = ProjectRepository(fileURL: directory.appendingPathComponent("projects.json"))
        #expect(throws: (any Error).self) { try repository.save([]) }
    }
}
