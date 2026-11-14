import Testing
@testable import TramaCore

struct EngineSessionSelectionTests {
    @Test func allSessionsAfterDefaultRenameUsesExistingGrouping() {
        let selection = EngineSessionSelection(sessions: ["trabalho"], preferredSession: "")

        #expect(selection.selectedSession == "trabalho")
        #expect(selection.options == ["trabalho"])
        #expect(!selection.options.contains("default"))
    }

    @Test func removedDefaultIsNotReintroducedByStalePreference() {
        let selection = EngineSessionSelection(sessions: ["trabalho"], preferredSession: "default")

        #expect(selection.selectedSession == "trabalho")
        #expect(selection.options == ["trabalho"])
    }

    @Test func explicitChoiceSurvivesSnapshotReorderingAndNewSessions() {
        let selection = EngineSessionSelection(sessions: ["trabalho", "default", "arquivo", "trabalho"],
                                               preferredSession: "trabalho")

        #expect(selection.selectedSession == "trabalho")
        #expect(selection.options == ["arquivo", "default", "trabalho"])
    }

    @Test func renameWhileFormIsOpenReplacesUnavailableChoice() {
        let before = EngineSessionSelection(sessions: ["default"], preferredSession: "default")
        let after = EngineSessionSelection(sessions: ["trabalho"], preferredSession: before.selectedSession)

        #expect(before.selectedSession == "default")
        #expect(after.selectedSession == "trabalho")
        #expect(after.options == ["trabalho"])
    }

    @Test func removingSelectedSessionChoosesDeterministicExistingAlternative() {
        let selection = EngineSessionSelection(sessions: ["zeta", "alpha"], preferredSession: "removida")

        #expect(selection.selectedSession == "alpha")
        #expect(selection.options == ["alpha", "zeta"])
    }

    @Test func noSessionsCannotProduceStartDestination() {
        let selection = EngineSessionSelection(sessions: [], preferredSession: "default")

        #expect(selection.selectedSession == nil)
        #expect(selection.options.isEmpty)
    }

    @Test func snapshotCanBecomeEmptyAndRecoverWhileFormRemainsOpen() {
        let before = EngineSessionSelection(sessions: ["trabalho"], preferredSession: "trabalho")
        let empty = EngineSessionSelection(sessions: [], preferredSession: before.selectedSession)
        let recovered = EngineSessionSelection(sessions: ["nova"], preferredSession: empty.selectedSession)

        #expect(empty.selectedSession == nil)
        #expect(empty.options.isEmpty)
        #expect(recovered.selectedSession == "nova")
        #expect(recovered.options == ["nova"])
    }

    @Test func emptySessionNameCannotBeUsedAsDestination() {
        let selection = EngineSessionSelection(sessions: [""], preferredSession: "")

        #expect(selection.selectedSession == nil)
        #expect(selection.options.isEmpty)
    }
}
