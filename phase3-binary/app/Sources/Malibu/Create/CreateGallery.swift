import AppKit
import Darwin

struct CreateImage: Identifiable, Hashable {
    let url: URL
    var id: String { url.lastPathComponent }
}

/// Owner-only gallery files, created relative to open directories so a symlink
/// cannot redirect a save outside Pictures/Malibu.
struct CreateGallery {
    let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
    var directory: URL { home.appendingPathComponent("Pictures", isDirectory: true).appendingPathComponent("Malibu", isDirectory: true) }

    func save(_ data: Data) throws -> CreateImage {
        guard data.count <= 24 * 1024 * 1024,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let bitmap = NSBitmapImageRep(data: data),
              [512, 1024].contains(bitmap.pixelsWide), bitmap.pixelsWide == bitmap.pixelsHigh,
              let png = bitmap.representation(using: .png, properties: [:])
        else { throw CreateFailure.malformed }
        let dir = try openDirectory(); defer { Darwin.close(dir) }
        let name = "Malibu-\(UUID().uuidString).png"
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw posixError() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            guard fchmod(fd, mode_t(0o600)) == 0 else { throw posixError() }
            try file.write(contentsOf: png)
            try file.synchronize()
            try file.close()
        } catch {
            try? file.close(); unlinkat(dir, name, 0)
            throw error
        }
        return CreateImage(url: directory.appendingPathComponent(name))
    }

    func load() throws -> [CreateImage] {
        let dir = try openDirectory(); defer { Darwin.close(dir) }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { url in
                guard url.lastPathComponent.hasPrefix("Malibu-"), url.pathExtension == "png" else { return false }
                var info = stat()
                return fstatat(dir, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0
                    && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()
                    && info.st_size <= 24 * 1024 * 1024
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { CreateImage(url: directory.appendingPathComponent($0.lastPathComponent)) }
    }

    private func openDirectory() throws -> Int32 {
        let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
        if mkdir(pictures.path, mode_t(0o700)) != 0 && errno != EEXIST { throw posixError() }
        let parent = open(pictures.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw posixError() }
        defer { Darwin.close(parent) }
        if mkdirat(parent, "Malibu", mode_t(0o700)) != 0 && errno != EEXIST { throw posixError() }
        let dir = openat(parent, "Malibu", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dir >= 0 else { throw posixError() }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == getuid(), fchmod(dir, mode_t(0o700)) == 0 else {
            let error = posixError(); Darwin.close(dir); throw error
        }
        return dir
    }
    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
