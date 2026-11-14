import Foundation

public final class StorageService: @unchecked Sendable {
    public let root: URL
    public let assets: URL
    public init(root: URL? = nil) throws {
        self.root =
            try root
            ?? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("ClipStack", isDirectory: true)
        assets = self.root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: assets.path)
    }
    public func storeImage(_ data: Data, hash: String) throws -> String {
        let name = hash + ".png"
        let file = assets.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: file.path) {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return name
    }
    public func assetURL(_ name: String) -> URL? {
        guard name == (name as NSString).lastPathComponent, !name.isEmpty, name != ".", name != ".." else { return nil }
        return assets.appendingPathComponent(name)
    }
    public func removeOrphans(keeping names: Set<String>) throws {
        for file in try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)
        where !names.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
