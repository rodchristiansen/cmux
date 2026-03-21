import Combine
import ConvexMobile
import Foundation

protocol TerminalServerDiscovering {
    var hostsPublisher: AnyPublisher<[TerminalHost], Never> { get }
}

final class TerminalServerDiscovery: TerminalServerDiscovering {
    let hostsPublisher: AnyPublisher<[TerminalHost], Never>

    @MainActor
    convenience init() {
        let convexClient = ConvexClientManager.shared.client
        let memberships = convexClient
            .subscribe(to: "teams:listTeamMemberships", yielding: TeamsListTeamMembershipsReturn.self)
            .catch { _ in
                Empty<TeamsListTeamMembershipsReturn, Never>()
            }
            .eraseToAnyPublisher()
        let machineHosts = Self.makeMachineHostsPublisher(
            teamMemberships: memberships,
            machineHostsForTeam: { teamID in
                convexClient
                    .subscribe(
                        to: "mobileMachines:listForUser",
                        with: ["teamSlugOrId": teamID],
                        yielding: [MobileMachineRow].self
                    )
                    .map { rows in
                        rows.map { $0.asTerminalHost() }
                    }
                    .catch { _ in
                        Just([])
                    }
                    .eraseToAnyPublisher()
            }
        )
        self.init(machineHosts: machineHosts, teamMemberships: memberships)
    }

    init(
        machineHosts: AnyPublisher<[TerminalHost], Never> = Just([]).eraseToAnyPublisher(),
        teamMemberships: AnyPublisher<TeamsListTeamMembershipsReturn, Never>
    ) {
        let legacyHosts = teamMemberships
            .map(Self.legacyHosts(from:))
            .eraseToAnyPublisher()

        self.hostsPublisher = Publishers.CombineLatest(machineHosts, legacyHosts)
            .map { machineHosts, legacyHosts in
                Self.merge(machineHosts: machineHosts, legacyHosts: legacyHosts)
            }
            .eraseToAnyPublisher()
    }

    static func makeMachineHostsPublisher(
        teamMemberships: AnyPublisher<TeamsListTeamMembershipsReturn, Never>,
        machineHostsForTeam: @escaping (String) -> AnyPublisher<[TerminalHost], Never>
    ) -> AnyPublisher<[TerminalHost], Never> {
        teamMemberships
            .map(uniqueTeamIDs(from:))
            .removeDuplicates()
            .map { teamIDs -> AnyPublisher<[TerminalHost], Never> in
                guard !teamIDs.isEmpty else {
                    return Just([]).eraseToAnyPublisher()
                }

                let initialState = Dictionary(
                    uniqueKeysWithValues: teamIDs.map { ($0, [TerminalHost]()) }
                )
                let publishers = teamIDs.map { teamID in
                    machineHostsForTeam(teamID)
                        .map { (teamID, $0) }
                        .eraseToAnyPublisher()
                }

                return Publishers.MergeMany(publishers)
                    .scan(initialState) { state, update in
                        var nextState = state
                        nextState[update.0] = update.1
                        return nextState
                    }
                    .map { hostRowsByTeam in
                        teamIDs.flatMap { hostRowsByTeam[$0] ?? [] }
                    }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .eraseToAnyPublisher()
    }

    private static func uniqueTeamIDs(from memberships: TeamsListTeamMembershipsReturn) -> [String] {
        var seen = Set<String>()
        return memberships.compactMap { membership in
            let teamID = membership.teamId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !teamID.isEmpty, seen.insert(teamID).inserted else {
                return nil
            }
            return teamID
        }
    }

    private static func legacyHosts(from memberships: TeamsListTeamMembershipsReturn) -> [TerminalHost] {
        memberships.flatMap { membership -> [TerminalHost] in
            guard let metadata = membership.team.serverMetadata?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !metadata.isEmpty,
                let catalog = try? TerminalServerCatalog(
                    metadataJSON: metadata,
                    teamID: membership.team.teamId
                ) else {
                return []
            }

            return catalog.hosts
        }
    }

    private static func merge(
        machineHosts: [TerminalHost],
        legacyHosts: [TerminalHost]
    ) -> [TerminalHost] {
        guard !machineHosts.isEmpty else {
            return legacyHosts
        }

        let legacyFallbackHosts = legacyHosts.filter { legacyHost in
            !machineHosts.contains { machineHost in
                TerminalServerCatalog.representsSameMachine(machineHost, legacyHost)
            }
        }
        return TerminalServerCatalog.merge(
            discovered: machineHosts + legacyFallbackHosts,
            local: []
        )
    }
}
