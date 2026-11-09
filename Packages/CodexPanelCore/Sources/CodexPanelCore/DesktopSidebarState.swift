import Foundation

public enum DesktopSidebarState {
    public static let scopeKey = "electron-account-renderer-state-v1"

    public enum MergeError: Error {
        case invalidState
        case missingSource
    }

    public struct ProjectIndex {
        public let roots: [String: [String]]
        public let threads: [String: Thread]

        public struct Thread {
            public let cwd: String
            public let projectID: String?

            public init(cwd: String, projectID: String?) {
                self.cwd = cwd
                self.projectID = projectID
            }
        }

        public init(roots: [String: [String]], threads: [String: Thread]) {
            self.roots = roots
            self.threads = threads
        }
    }

    /// Merge only the local project projection into the target identity's saved sidebar.
    public static func merge(
        _ state: [String: Any],
        source: String,
        target: String,
        codexHome: URL,
        destinationHome: URL? = nil,
        projectIndex: () throws -> ProjectIndex
    ) throws -> Data? {
        let sourceHost = "local:\(codexHome.resolvingSymlinksInPath().path)"
        let host = "local:\((destinationHome ?? codexHome).resolvingSymlinksInPath().path)"
        guard source != target || sourceHost != host, let rawScope = state[scopeKey] else { return nil }
        guard var scope = rawScope as? [String: Any],
              var inactive = scope["inactive"] as? [String: [String: Any]],
              scope["owner"] is String || scope["owner"] is NSNull
        else { throw MergeError.invalidState }

        let active = scope["owner"] as? String
        let atomKey = "electron-persisted-atom-state"
        let projectKey = "local-projects"
        let mapKey = "app-server-project-id-by-legacy-project-id-by-host"
        let assignmentKey = "thread-project-assignments"
        let orderKey = "sidebar-project-thread-orders"
        let projectPrefix = "codex:project:"
        guard let from = active == source ? state : inactive[source]?["globals"] as? [String: Any]
        else { throw MergeError.missingSource }
        guard let sourceProjects = from[projectKey] as? [String: [String: Any]], !sourceProjects.isEmpty
        else { return nil }
        let fromAtoms = (active == source ? state[atomKey] : inactive[source]?["atoms"]) as? [String: Any] ?? [:]
        let destination = inactive[target] ?? [:]
        guard destination["globals"] == nil || destination["globals"] is [String: Any],
              destination["atoms"] == nil || destination["atoms"] is [String: Any]
        else { throw MergeError.invalidState }
        var globals = active == target ? state : destination["globals"] as? [String: Any] ?? [:]
        var atoms = (active == target ? state[atomKey] : destination["atoms"]) as? [String: Any] ?? [:]
        let previousGlobals = globals
        let previousAtoms = atoms
        var projects = globals[projectKey] as? [String: [String: Any]] ?? [:]
        var mappings = globals[mapKey] as? [String: [String: String]] ?? [:]
        let sourceMapping = (from[mapKey] as? [String: [String: String]])?[sourceHost] ?? [:]
        var targetMapping = mappings[host] ?? mappings[sourceHost] ?? [:]
        let index = try projectIndex()
        func canonicalPath(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let storedRoots = index.roots.mapValues { Set($0.map(canonicalPath)) }
        let threads = index.threads

        let cloudFields: Set<String> = [
            "chatGptBacking", "chatGptBackingCreation", "retiredChatGptBacking", "chatGptBackingRecoveryPending",
        ]
        func isLocal(_ project: [String: Any]) -> Bool {
            cloudFields.isDisjoint(with: project.keys)
        }

        var shared: Set<String> = []
        for (id, project) in sourceProjects.sorted(by: { $0.key < $1.key }) {
            guard isLocal(project), project["id"] as? String == id,
                  let serverID = sourceMapping[id],
                  let paths = project["rootPaths"] as? [String], !paths.isEmpty,
                  paths.allSatisfy({ $0.hasPrefix("/") }),
                  Set(paths.map(canonicalPath)) == storedRoots[serverID],
                  targetMapping[id] == nil || targetMapping[id] == serverID,
                  !targetMapping.contains(where: { $0.key != id && $0.value == serverID })
            else { continue }
            if let existing = projects[id] {
                guard isLocal(existing), let existingPaths = existing["rootPaths"] as? [String],
                      Set(existingPaths.map(canonicalPath)) == Set(paths.map(canonicalPath)) else { continue }
            } else {
                guard !projects.contains(where: { otherID, other in
                    guard sourceProjects[otherID] == nil, let existing = other["rootPaths"] as? [String]
                    else { return false }
                    return Set(existing.map(canonicalPath)) == Set(paths.map(canonicalPath))
                }) else { continue }
                projects[id] = project
            }
            targetMapping[id] = serverID
            shared.insert(id)
        }
        guard !shared.isEmpty else {
            if sourceProjects.values.contains(where: isLocal) { throw MergeError.missingSource }
            return nil
        }
        mappings[host] = targetMapping
        globals[projectKey] = projects
        globals[mapKey] = mappings

        var assignments = globals[assignmentKey] as? [String: [String: Any]] ?? [:]
        let targetProjectless = Set(globals["projectless-thread-ids"] as? [String] ?? [])
        let sourceHosts = from["thread-project-membership-host-ids"] as? [String: String] ?? [:]
        let targetHosts = globals["thread-project-membership-host-ids"] as? [String: String] ?? [:]
        for (thread, assignment) in from[assignmentKey] as? [String: [String: Any]] ?? [:] {
            guard assignments[thread] == nil, !targetProjectless.contains(thread),
                  sourceHosts[thread, default: "local"] == "local",
                  targetHosts[thread, default: "local"] == "local",
                  assignment["projectKind"] as? String == "local",
                  let id = assignment["projectId"] as? String, shared.contains(id),
                  let stored = threads[thread], stored.projectID == nil || stored.projectID == targetMapping[id]
            else { continue }
            assignments[thread] = ["projectKind": "local", "projectId": id]
        }
        if !assignments.isEmpty { globals[assignmentKey] = assignments }

        func combine(_ first: [String], _ remaining: [String]) -> [String] {
            var seen: Set<String> = []
            return (first + remaining).filter { seen.insert($0).inserted }
        }
        for key in ["pinned-project-ids", "project-order"] {
            let saved = (from[key] as? [String] ?? []).filter(shared.contains)
            let existing = globals[key] as? [String] ?? []
            if !saved.isEmpty {
                globals[key] = combine(saved, existing)
            }
        }
        let localRoots = projects.flatMap { id, project in
            (project["rootPaths"] as? [String] ?? []).map { (id, canonicalPath($0)) }
        }
        func belongs(_ thread: String, to id: String) -> Bool {
            guard let stored = threads[thread], !targetProjectless.contains(thread),
                  targetHosts[thread, default: "local"] == "local",
                  stored.projectID == nil || stored.projectID == targetMapping[id]
            else { return false }
            if let assignment = assignments[thread] {
                return assignment["projectKind"] as? String == "local" && assignment["projectId"] as? String == id
            }
            if stored.projectID != nil { return true }
            guard stored.cwd.hasPrefix("/") else { return false }
            let cwd = canonicalPath(stored.cwd)
            let matches = localRoots.filter { _, root in
                cwd == root || cwd.hasPrefix(root == "/" ? root : root + "/")
            }
            guard let length = matches.map({ $0.1.count }).max() else { return false }
            return Set(matches.filter { $0.1.count == length }.map { $0.0 }) == [id]
        }
        var orders = globals[orderKey] as? [String: [String: Any]] ?? [:]
        for (id, record) in from[orderKey] as? [String: [String: Any]] ?? [:] where shared.contains(id) {
            let saved = (record["threadIds"] as? [String] ?? []).filter { belongs($0, to: id) }
            if !saved.isEmpty {
                var existing = orders[id] ?? [:]
                existing["threadIds"] = combine(saved, existing["threadIds"] as? [String] ?? [])
                orders[id] = existing
            }
        }
        if !orders.isEmpty { globals[orderKey] = orders }

        let unifiedKey = "unified-sidebar-project-order-v1"
        let unified = (fromAtoms[unifiedKey] as? [String] ?? []).filter {
            $0.hasPrefix(projectPrefix) && shared.contains(String($0.dropFirst(projectPrefix.count)))
        }
        if !unified.isEmpty {
            atoms[unifiedKey] = combine(unified, atoms[unifiedKey] as? [String] ?? [])
        }
        let sortKey = "flat-project-sidebar-preferences-v1"
        if let saved = fromAtoms[sortKey] as? [String: Any] {
            var preferences = atoms[sortKey] as? [String: Any] ?? [:]
            for key in ["chatSortMode", "projectSortMode", "manualSortVersion"] {
                if let value = saved[key] { preferences[key] = value }
            }
            atoms[sortKey] = preferences
        }
        for id in shared {
            let key = "sidebar-project-expanded-v1-codex:\(id)"
            if let expanded = fromAtoms[key] as? Bool { atoms[key] = expanded }
        }

        guard !NSDictionary(dictionary: globals).isEqual(to: previousGlobals)
                || !NSDictionary(dictionary: atoms).isEqual(to: previousAtoms)
        else { return nil }
        var result = state
        if active == target {
            result = globals
            result[atomKey] = atoms
        } else {
            var saved = destination
            saved["globals"] = globals
            saved["atoms"] = atoms
            inactive[target] = saved
            scope["inactive"] = inactive
            result[scopeKey] = scope
        }
        return try JSONSerialization.data(withJSONObject: result)
    }
}
