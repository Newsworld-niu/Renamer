import Foundation

struct RaycastDesktop: Codable {
    let id: String
    let name: String
    let screen: String
    let position: Int
    let current: Bool
}

struct RaycastListing: Codable {
    let desktops: [RaycastDesktop]
}

enum RaycastBridge {
    static func list() throws -> Data {
        let spaces = try SpaceSystem().read()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Renamer", isDirectory: true)
        let store = NameStore(url: directory.appendingPathComponent("names.json"), bootID: SpaceSystem.bootID())
        if let error = store.loadError { throw RenamerError.message(error) }
        let desktops = spaces.filter(\.isOrdinary).map { space in
            RaycastDesktop(id: space.identity(bootID: store.bootID), name: store.name(space),
                           screen: space.screenName, position: space.position, current: space.isCurrent)
        }
        return try JSONEncoder().encode(RaycastListing(desktops: desktops))
    }

    static func targetID(from url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "renamer-spaces", parts.host == "switch",
              let id = parts.queryItems?.first(where: { $0.name == "target" })?.value,
              !id.isEmpty else { return nil }
        return id
    }
}
