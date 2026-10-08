import Foundation
@testable import Tailcat
import Testing

extension LoopbackTests {
    @Test func downloadsRejectRemoteSymbolicLinks() async throws {
        let context = try await LoopbackContext.create()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("owned".utf8).write(to: root.appendingPathComponent("file"))
        try Data("child".utf8).write(to: root.appendingPathComponent("folder/child"))
        for (name, target) in [("file-link", "file"), ("directory-link", "folder"), ("self-link", "self-link")] {
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(name).path, withDestinationPath: target)
        }
        let service = try await context.server.serveSSH(configuration: .init(authentication: .none,
            files: .init(directory: root, mode: .readWrite)), port: 2222)
        let files = try await context.client.openSSH(configuration: .init(hostKey: #require(service.hostKey),
            port: 2222, user: "owned-test")).openSFTP()
        for name in ["file-link", "directory-link", "self-link"] {
            await #expect(throws: TailcatError.unsupported("recursive symbolic-link transfer is unsupported")) {
                try await files.download(directory: base.appendingPathComponent("downloads"), paths: [name], recursive: true)
            }
        }
        try await context.runtime.close()
    }

    @Test func recursiveTransfersAndMetadata() async throws {
        let context = try await LoopbackContext.create()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let root = base.appendingPathComponent("root")
        let downloads = base.appendingPathComponent("downloads")
        for directory in [source.appendingPathComponent("nested"), root] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = Data(repeating: 0x42, count: 180_000)
        let file = source.appendingPathComponent("nested/large.bin")
        try data.write(to: file)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o640, .modificationDate: modified], ofItemAtPath: file.path)
        let service = try await context.server.serveSSH(configuration: .init(authentication: .none,
            files: .init(directory: root, mode: .readWrite)), port: 2222)
        let files = try await context.client.openSSH(configuration: .init(hostKey: #require(service.hostKey),
            port: 2222, user: "owned-test")).openSFTP()
        try await files.upload(files: [source], path: ".", preserveMetadata: true, recursive: true)
        let info = try await files.stat(path: "source/nested/large.bin")
        #expect(info.size == 180_000 && info.mode & 0o777 == 0o640)
        #expect(abs(info.modificationDate.timeIntervalSince(modified)) < 1)
        try await files.download(directory: downloads, paths: ["source"], preserveMetadata: true, recursive: true)
        #expect(try Data(contentsOf: downloads.appendingPathComponent("source/nested/large.bin")) == data)
        try await context.runtime.close()
    }

    @Test func writeOnlyChunkedUploadsUseOneRemoteHandle() async throws {
        for mode in [FileServeMode.writeOnly, .writeOnlyRecursive] {
            let context = try await LoopbackContext.create()
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: base) }
            let source = base.appendingPathComponent("source")
            let root = base.appendingPathComponent("root")
            for directory in [source, root] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            let data = Data(repeating: 0x37, count: 180_000)
            let local = source.appendingPathComponent("large.bin")
            try data.write(to: local)
            let service = try await context.server.serveSSH(configuration: .init(authentication: .none,
                files: .init(directory: root, mode: mode)), port: 2222)
            let files = try await context.client.openSSH(configuration: .init(hostKey: #require(service.hostKey),
                port: 2222, user: "owned-test")).openSFTP()
            if mode == .writeOnly {
                try await files.upload(files: [local], path: ".")
                try await files.upload(files: [local], path: ".")
                let results = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                #expect(results.count == 2)
                for file in results { #expect(try Data(contentsOf: file) == data) }
            } else {
                try await files.upload(files: [source], path: ".", recursive: true)
                #expect(try Data(contentsOf: root.appendingPathComponent("source/large.bin")) == data)
            }
            await #expect(throws: (any Error).self) { try await files.read(path: "large.bin") }
            try await context.runtime.close()
        }
    }
}
