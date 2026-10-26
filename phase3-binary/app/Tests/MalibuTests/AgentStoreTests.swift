import Darwin
import XCTest
@testable import Malibu

@MainActor
final class AgentStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testRoundTripUsesOwnerOnlyDirectoryAndFiles() throws {
        let root = try directory()
        let store = AgentStore(directory: root)
        var definition = AgentDefinition(name: "Research", instructions: "Read carefully.")
        definition.workspacePath = "/tmp/workspace"
        definition.workspaceTools = true
        definition.target = .network
        definition.model = "tool-model"
        try store.save(definition)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("agents.json").path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(AgentStore(directory: root).agents, [definition])
        definition.name = "Updated"
        try store.save(definition)
        XCTAssertEqual(store.agents.count, 1)
        XCTAssertEqual(AgentStore(directory: root).agents.first?.name, "Updated")
        try store.remove(definition)
        XCTAssertTrue(AgentStore(directory: root).agents.isEmpty)
    }

    func testPersistedSchemaHasNoBuyerKeyOrCredentialField() throws {
        let root = try directory()
        let store = AgentStore(directory: root)
        try store.save(AgentDefinition(name: "Network", target: .network, model: "fixture"))
        let data = try Data(contentsOf: root.appendingPathComponent("agents.json"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), ["id", "name", "instructions", "target", "model", "workspaceTools", "servers", "sampling"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("buyerKey"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Authorization"))
    }

    func testUnsafeSymlinkIsNotReadOrModified() throws {
        let root = try directory()
        let external = root.appendingPathComponent("external.json")
        let bytes = Data("[]".utf8)
        try bytes.write(to: external)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("agents.json"), withDestinationURL: external)
        let store = AgentStore(directory: root)
        XCTAssertNotNil(store.notice)
        XCTAssertTrue(store.agents.isEmpty)
        XCTAssertEqual(try Data(contentsOf: external), bytes)
    }

    func testInvalidSamplingAndOversizedInstructionsNeverPersist() throws {
        let root = try directory()
        let store = AgentStore(directory: root)
        var agent = AgentDefinition()
        agent.sampling.maxTokens = 8193
        XCTAssertThrowsError(try store.save(agent))
        agent.sampling.maxTokens = 1024
        agent.sampling.temperature = .nan
        XCTAssertThrowsError(try store.save(agent))
        agent.sampling.temperature = 0.7
        agent.instructions = String(repeating: "x", count: 16_385)
        XCTAssertThrowsError(try store.save(agent))
        XCTAssertTrue(store.agents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("agents.json").path))
    }

    func testCorruptAndOversizedStoresFailVisibly() throws {
        let root = try directory()
        let file = root.appendingPathComponent("agents.json")
        try Data("not json".utf8).write(to: file)
        XCTAssertNotNil(AgentStore(directory: root).notice)
        try Data(repeating: 0, count: 1_048_577).write(to: file)
        XCTAssertNotNil(AgentStore(directory: root).notice)
    }
}
