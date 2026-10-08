import Foundation

extension Tailcat.SFTP {
    public func download(directory: URL, paths: [String], preserveMetadata: Bool = false,
                         recursive: Bool = false) async throws {
        guard directory.isFileURL else { throw Tailcat.Failure.invalidInput("download requires a local directory") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for path in paths {
            let name = (path as NSString).lastPathComponent
            try validateTransferName(name)
            try await downloadOne(local: directory.appendingPathComponent(name), path: path,
                                  preserveMetadata: preserveMetadata, recursive: recursive)
        }
    }

    public func upload(files: [URL], path: String, preserveMetadata: Bool = false,
                       recursive: Bool = false) async throws {
        for file in files {
            guard file.isFileURL else { throw Tailcat.Failure.invalidInput("upload requires local file URLs") }
            try validateTransferName(file.lastPathComponent)
            try await uploadOne(file: file, path: joinRemote(path, file.lastPathComponent),
                                preserveMetadata: preserveMetadata, recursive: recursive)
        }
    }

    private func downloadOne(local: URL, path: String, preserveMetadata: Bool, recursive: Bool) async throws {
        try Task.checkCancellation()
        let info = try await lstat(path: path)
        guard info.mode & (1 << 27) == 0 else { throw Tailcat.Failure.unsupported("recursive symbolic-link transfer is unsupported") }
        if info.isDirectory {
            guard recursive else { throw Tailcat.Failure.invalidInput("directory transfer requires recursive=true") }
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            for child in try await list(path: path) {
                if child.name == "." || child.name == ".." { continue }
                try validateTransferName(child.name)
                try await downloadOne(local: local.appendingPathComponent(child.name), path: joinRemote(path, child.name),
                                      preserveMetadata: preserveMetadata, recursive: true)
            }
        } else {
            let temporary = local.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).download")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw Tailcat.Failure.operationFailed("cannot create temporary download file")
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let file = try FileHandle(forWritingTo: temporary)
            defer { try? file.close() }
            let remote = try await openFile(path: path)
            var offset: Int64 = 0
            do {
                while let data = try await remote.read(offset: offset), !data.isEmpty {
                    try Task.checkCancellation()
                    try file.write(contentsOf: data)
                    offset += Int64(data.count)
                }
                try await remote.close()
            } catch {
                try? await remote.close()
                throw error
            }
            try file.synchronize()
            if FileManager.default.fileExists(atPath: local.path) {
                _ = try FileManager.default.replaceItemAt(local, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: local) }
        }
        if preserveMetadata {
            try FileManager.default.setAttributes([.modificationDate: info.modificationDate,
                                                    .posixPermissions: NSNumber(value: info.mode & 0o777)], ofItemAtPath: local.path)
        }
    }

    private func uploadOne(file: URL, path: String, preserveMetadata: Bool, recursive: Bool) async throws {
        try Task.checkCancellation()
        let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw Tailcat.Failure.unsupported("recursive symbolic-link transfer is unsupported") }
        if values.isDirectory == true {
            guard recursive else { throw Tailcat.Failure.invalidInput("directory transfer requires recursive=true") }
            do { try await makeDirectory(path: path) }
            catch {
                guard try await stat(path: path).isDirectory else { throw error }
            }
            for child in try FileManager.default.contentsOfDirectory(at: file, includingPropertiesForKeys: nil) {
                try validateTransferName(child.lastPathComponent)
                try await uploadOne(file: child, path: joinRemote(path, child.lastPathComponent),
                                    preserveMetadata: preserveMetadata, recursive: true)
            }
        } else {
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            let remote = try await openFile(options: .init(create: true, truncate: true, write: true), path: path)
            var offset: Int64 = 0
            do {
                while let data = try input.read(upToCount: 65_536), !data.isEmpty {
                    try Task.checkCancellation()
                    let count = try await remote.write(data, offset: offset)
                    guard count == data.count else { throw Tailcat.Failure.operationFailed("short file write") }
                    offset += Int64(count)
                }
                try await remote.close()
            } catch {
                try? await remote.close()
                throw error
            }
        }
        if preserveMetadata {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            if let permissions = attributes[.posixPermissions] as? NSNumber { try await chmod(path: path, permissions: permissions.uint32Value) }
            if let modified = attributes[.modificationDate] as? Date { try await setTimes(access: modified, modification: modified, path: path) }
        }
    }
}

private func joinRemote(_ path: String, _ name: String) -> String {
    path.hasSuffix("/") ? path + name : path + "/" + name
}

private func validateTransferName(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
        throw Tailcat.Failure.invalidInput("unsafe file transfer name")
    }
}
