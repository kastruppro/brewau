import Foundation
import Darwin

/// Destination and its parents belong to root in production. Publish bytes, never links.
func copyCompletions(from source: URL, into destination: URL, prefix: URL, owner: uid_t, group: gid_t) throws -> Int {
    let fm = FileManager.default
    try fm.createDirectory(at: destination, withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o755, .ownerAccountID: owner, .groupOwnerAccountID: group])
    let prefixPath = prefix.resolvingSymlinksInPath().path + "/"
    let sources = fm.fileExists(atPath: source.path) ? try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) : []
    var kept: Set<String> = []
    for source in sources {
        let name = source.lastPathComponent
        guard name.range(of: "^_[A-Za-z0-9][A-Za-z0-9._+\\-]*$", options: .regularExpression) != nil else { continue }
        let resolved = source.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(prefixPath), let attributes = try? fm.attributesOfItem(atPath: resolved.path) else { continue }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 4_194_304 else { continue }
        let target = destination.appendingPathComponent(name)
        try Data(contentsOf: resolved).write(to: target, options: .atomic)
        guard chmod(target.path, 0o644) == 0, chown(target.path, owner, group) == 0 else { throw BrewauError.message("Could not protect completion \(name).") }
        kept.insert(name)
    }
    for target in try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) where !kept.contains(target.lastPathComponent) {
        try fm.removeItem(at: target)
    }
    return kept.count
}
