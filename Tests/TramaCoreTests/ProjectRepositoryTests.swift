import Foundation
import Darwin
import Testing
@testable import TramaCore

struct ProjectRepositoryTests {
    private func withStore(_ body: (ProjectRepository) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(ProjectRepository(fileURL: directory.appendingPathComponent("nested/projects.json")))
    }

    @Test func registrationsFromStaleInstancesPreserveBothProjects() throws {
        try withStore { first in
            let second = ProjectRepository(fileURL: first.fileURL)
            #expect(try first.load().isEmpty)
            #expect(try second.load().isEmpty)
            let root = first.fileURL.deletingLastPathComponent()
            let a = root.appendingPathComponent("a")
            let b = root.appendingPathComponent("b")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            let registeredA = try first.register(a)
            let registeredB = try second.register(b)
            #expect(registeredB.projects == [registeredA.project, registeredB.project])
            #expect(try first.load() == registeredB.projects)
            let duplicate = try second.register(a)
            #expect(duplicate.project.id == registeredA.project.id)
            #expect(duplicate.projects.count == 2)
        }
    }

    @Test func registrationPreservesCorruptStoreAndReleasesLockOnError() throws {
        try withStore { repository in
            try repository.save([])
            let corrupt = Data("not valid json".utf8)
            try corrupt.write(to: repository.fileURL)
            let directory = repository.fileURL.deletingLastPathComponent()
            #expect(throws: (any Error).self) { try repository.register(directory) }
            #expect(try Data(contentsOf: repository.fileURL) == corrupt)
            try repository.save([])
            #expect(try repository.register(directory).projects.count == 1)
        }
    }

    @Test func occupiedLockRejectsRegistrationWithoutChangingStore() throws {
        try withStore { repository in
            try repository.save([])
            let before = try Data(contentsOf: repository.fileURL)
            let descriptor = open(repository.fileURL.path + ".lock", O_RDWR)
            #expect(descriptor >= 0)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            let directory = repository.fileURL.deletingLastPathComponent()
            #expect(throws: ProjectRepository.RepositoryError.self) {
                try repository.register(directory)
            }
            #expect(try Data(contentsOf: repository.fileURL) == before)
            #expect(flock(descriptor, LOCK_UN) == 0)
            #expect(try repository.register(directory).projects.count == 1)
        }
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
