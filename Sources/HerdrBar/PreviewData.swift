import Foundation
import HerdrBarCore

/// Sample data is used only by the explicit --render-preview command.
enum PreviewData {
    static func snapshot(attention: Bool = false, extended: Bool = false) throws -> SessionSnapshot {
        let names = extended
            ? (0..<18).map { $0 == 0 ? "payment-api-production-migration" : "workspace-\($0 + 1)" }
            : ["payment-api", "games-tw", "remakan", "ragnarok-game", "tinydash", "tinydash"]
        let agents: [[String: Any]] = names.enumerated().map { index, _ in
            let workspace = extended ? index : min(index, 4)
            let status = attention && index == 0 ? "blocked" : attention && index == 2 ? "done"
                : extended && index == 1 ? "unknown" : index == 5 ? "working" : "idle"
            return ["pane_id": "w\(workspace):p\(index)", "terminal_id": "term_\(index)",
                    "workspace_id": "w\(workspace)", "tab_id": "t\(index)",
                    "agent": "codex", "agent_status": status, "focused": index == names.count - 1]
        }
        let workspaces: [[String: Any]] = names.prefix(extended ? names.count : 5).enumerated().map {
            ["workspace_id": "w\($0.offset)", "label": $0.element, "number": $0.offset]
        }
        let tabs: [[String: Any]] = names.enumerated().map {
            ["tab_id": "t\($0.offset)", "label": extended && $0.offset == 0
                ? "orchestrator-with-a-long-tab-name" : $0.offset == 2 ? "orchestrator" : $0.offset == 5 ? "2" : "1",
             "number": $0.offset]
        }
        return try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject:
            ["version": "preview", "agents": agents, "workspaces": workspaces, "tabs": tabs]))
    }

    static func empty() throws -> SessionSnapshot {
        try JSONDecoder().decode(SessionSnapshot.self, from:
            Data(#"{"version":"preview","agents":[],"workspaces":[],"tabs":[]}"#.utf8))
    }
}
