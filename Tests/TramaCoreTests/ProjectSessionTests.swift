import Foundation
import Testing
@testable import TramaCore

struct ProjectSessionTests {
    private func withRepository(_ body: (ProjectSessionRepository) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(ProjectSessionRepository(fileURL: root.appendingPathComponent("sessions.json")))
    }

    @Test func emptySessionsSurviveReloadAndStayInTheirProject() throws {
        try withRepository { repository in
            let a = Project(name: "A", path: "/tmp/a"), b = Project(name: "B", path: "/tmp/b")
            _ = try repository.save(ProjectSession(projectID: a.id, engineID: "one", name: "Landing page"))
            _ = try ProjectSessionRepository(fileURL: repository.fileURL).save(
                ProjectSession(projectID: b.id, engineID: "two", name: "Landing page"))
            let catalog = try repository.load()
            let groups = WorkspaceProjectGroup.groups(projects: [a, b], agents: [], catalog: catalog)
            #expect(Set(groups[0].sessions) == ["one", ProjectSession.generalID(for: a.id)])
            #expect(Set(groups[1].sessions) == ["two", ProjectSession.generalID(for: b.id)])
            #expect(ProjectSession.generalID(for: a.id) != ProjectSession.generalID(for: b.id))
        }
    }

    @Test func legacyLabelCanChangeInOneProjectWithoutChangingEngineIdentity() throws {
        try withRepository { repository in
            let a = UUID(), b = UUID()
            let catalog = try repository.save(ProjectSession(projectID: a, engineID: "media", name: "Geral"))
            #expect(ProjectSession.name(for: "media", projectID: a, catalog: catalog) == "Geral")
            #expect(ProjectSession.name(for: "media", projectID: b, catalog: catalog) == "media")
            #expect(ProjectSession.initialID(for: a, catalog: catalog) == "media")
            #expect(ProjectSession.initialID(for: b, catalog: catalog) != "media")
        }
    }

    @Test func corruptionAndUnsupportedVersionsArePreserved() throws {
        try withRepository { repository in
            _ = try repository.load()
            for text in ["broken", "{\"version\":2,\"sessions\":[]}", "{\"version\":1,\"sessions\":[{}]}"] {
                let bytes = Data(text.utf8)
                try bytes.write(to: repository.fileURL)
                #expect(throws: (any Error).self) { try repository.load() }
                #expect(throws: (any Error).self) {
                    try repository.save(ProjectSession(projectID: UUID(), engineID: "id", name: "Geral"))
                }
                #expect(try Data(contentsOf: repository.fileURL) == bytes)
            }
        }
    }

    @Test func duplicateNamesAndWriteFailurePreservePreviousCatalog() throws {
        try withRepository { repository in
            let project = UUID()
            let before = try repository.save(ProjectSession(projectID: project, engineID: "one", name: "Geral"))
            #expect(throws: (any Error).self) {
                try repository.save(ProjectSession(projectID: project, engineID: "two", name: "Geral"))
            }
            let failing = ProjectSessionRepository(fileURL: repository.fileURL, writer: { _, _ in throw CocoaError(.fileWriteUnknown) })
            #expect(throws: (any Error).self) {
                try failing.save(ProjectSession(projectID: project, engineID: "one", name: "Renamed"))
            }
            #expect(try repository.load() == before)
        }
    }
}
