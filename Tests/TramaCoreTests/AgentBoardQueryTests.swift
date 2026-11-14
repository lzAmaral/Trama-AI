import Foundation
import Testing
@testable import TramaCore

struct AgentBoardQueryTests {
    @Test func projectFilterNeverLeaksOtherProjects() {
        let a = Project(name: "App", path: "/tmp/app")
        let b = Project(name: "Site", path: "/tmp/site")
        let sessions = DemoSessions.make(projects: [a, b])
        let filtered = AgentBoardQuery.filter(sessions, projectID: a.id, search: "")
        #expect(filtered.count == 4)
        #expect(filtered.allSatisfy { $0.projectID == a.id })
        #expect(AgentBoardQuery.filter(sessions, projectID: UUID(), search: "").isEmpty)
    }

    @Test func searchCombinesWithProjectAndMatchesProvider() {
        let a = Project(name: "Portfólio", path: "/tmp/portfolio")
        let b = Project(name: "Site", path: "/tmp/site")
        let sessions = DemoSessions.make(projects: [a, b])
        #expect(AgentBoardQuery.filter(sessions, projectID: a.id, search: "  codex  ").count == 2)
        #expect(AgentBoardQuery.filter(sessions, projectID: nil, search: "PORTFOLIO").count == 4)
        #expect(AgentBoardQuery.filter(sessions, projectID: a.id, search: "Site").isEmpty)
        #expect(AgentBoardQuery.filter(sessions, projectID: nil, search: " \n ").count == 8)
    }

    @Test func adjacentProjectIDsKeepDistinctSessionIdentities() throws {
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let projects = [Project(id: firstID, name: "A", path: "/a"),
                        Project(id: secondID, name: "B", path: "/b")]
        let sessions = DemoSessions.make(projects: projects)
        #expect(Set(sessions.map(\.id)).count == 8)
        #expect(sessions == DemoSessions.make(projects: projects))
    }

    @Test func demoCanBeExploredWithoutRegisteringAProject() {
        let first = DemoSessions.make(projects: [])
        let second = DemoSessions.make(projects: [])
        #expect(first == second)
        #expect(Set(first.map(\.id)).count == first.count)
        #expect(Set(first.map(\.status)) == Set(AgentStatus.allCases))
    }
}
