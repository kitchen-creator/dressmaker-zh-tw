import Foundation
import AppKit
import CryptoKit

private let supportedPatchVersion = "1.7"
private let backupFolderName = ".dressmaker-zh-tw-backup-v1.7"
private let backupRecordName = "backup-record.json"
private let supportedResourcePaths: Set<String> = [
    "aa/StandaloneOSX/localization-string-tables-chinese(simplified)(zh-hans)_assets_all.bundle",
    "aa/catalog.bin",
    "aa/catalog.hash",
    "aa/StandaloneOSX/localization-assets-chinese(simplified)(zh-hans)_assets_all.bundle"
]

enum PatchError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

struct PatchFile: Codable {
    let relativePath: String
    let originalSHA256: String
    let originalSize: Int64
    let patchedSHA256: String
    let patchedSize: Int64
    let deltaPath: String
    let deltaSHA256: String
    let deltaSize: Int64
    enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case originalSHA256 = "original_sha256"
        case originalSize = "original_size"
        case patchedSHA256 = "patched_sha256"
        case patchedSize = "patched_size"
        case deltaPath = "delta_path"
        case deltaSHA256 = "delta_sha256"
        case deltaSize = "delta_size"
    }
}

struct PatchManifest: Codable {
    let schemaVersion: Int
    let patchVersion: String
    let platform: String
    let steamAppID: Int
    let steamBuildID: String
    let gameVersion: String
    let files: [PatchFile]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case patchVersion = "patch_version"
        case platform
        case steamAppID = "steam_appid"
        case steamBuildID = "steam_buildid"
        case gameVersion = "game_version"
        case files
    }
}

private struct BackupFile: Codable, Equatable {
    let relativePath: String
    let sha256: String
    let size: Int64
    enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case sha256, size
    }
}

private struct BackupRecord: Codable {
    let schemaVersion: Int
    let patchVersion: String
    let manifestSHA256: String
    let files: [BackupFile]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case patchVersion = "patch_version"
        case manifestSHA256 = "manifest_sha256"
        case files
    }
}

enum InstallationState: String {
    case original
    case patched
}

/// Core operations are independent of UI and process discovery. The executable
/// supplies mutationGuard; test builds call this class using temporary fixtures.
final class Engine {
    let packageRoot: URL
    let gameApp: URL
    let streamingRoot: URL
    let backupRoot: URL
    let manifest: PatchManifest
    private let manifestSHA256: String
    private let fileManager = FileManager.default
    var mutationGuard: (() throws -> Void)?
    #if INSTALLER_TESTING
    var testingFailureAfterReplacements: Int?
    #endif

    init(packageRoot: URL, gameApp: URL) throws {
        self.packageRoot = packageRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.gameApp = gameApp.standardizedFileURL.resolvingSymlinksInPath()
        guard self.gameApp.pathExtension.lowercased() == "app" else {
            throw PatchError.message("請選擇 Dressmaker.app。")
        }
        try Self.requireDirectory(self.packageRoot)
        try Self.requireDirectory(self.gameApp)
        let streaming = self.gameApp.appendingPathComponent("Contents/Resources/Data/StreamingAssets", isDirectory: true)
        self.streamingRoot = streaming.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isContained(self.streamingRoot, in: self.gameApp) else {
            throw PatchError.message("遊戲資源路徑超出所選 app，已停止。")
        }
        try Self.requireDirectory(self.streamingRoot)
        self.backupRoot = self.gameApp.deletingLastPathComponent().appendingPathComponent(backupFolderName, isDirectory: true)
        let manifestURL = try Self.safeURL(root: self.packageRoot, relativePath: "manifest.json")
        try Self.requireRegularFile(manifestURL)
        let manifestData = try Data(contentsOf: manifestURL)
        self.manifestSHA256 = Self.sha256(manifestData)
        self.manifest = try JSONDecoder().decode(PatchManifest.self, from: manifestData)
        try validateManifest()
        try validatePackage()
    }

    func check() throws -> InstallationState {
        var originals = 0
        var patched = 0
        for file in manifest.files {
            let source = try Self.safeURL(root: streamingRoot, relativePath: file.relativePath)
            let identity = try Self.identity(source)
            if identity.sha256 == file.originalSHA256 && identity.size == file.originalSize {
                originals += 1
            } else if identity.sha256 == file.patchedSHA256 && identity.size == file.patchedSize {
                patched += 1
            } else {
                throw PatchError.message("資源 \(file.relativePath) 不符合支援版本。可能遊戲已更新或裝有其他補丁；未更動任何遊戲檔案。")
            }
        }
        if originals == manifest.files.count { return .original }
        if patched == manifest.files.count { return .patched }
        throw PatchError.message("偵測到原版與補丁資源混用，已停止。請先使用 Steam 驗證遊戲檔案，恢復一致的原版後再安裝。")
    }

    func install() throws {
        try mutationGuard?()
        try validatePackage()
        let state = try check()
        if state == .patched {
            try validateBackup()
            return
        }
        try ensureOriginalBackup()
        try transact(from: .original, to: .patched) { [self] incoming in
            for file in manifest.files {
                let original = try Self.safeURL(root: streamingRoot, relativePath: file.relativePath)
                let delta = try Self.safeURL(root: packageRoot, relativePath: file.deltaPath)
                let destination = try Self.safeURL(root: incoming, relativePath: file.relativePath)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try runBSPatch(original: original, destination: destination, delta: delta, logRoot: incoming)
                try Self.verify(destination, sha256: file.patchedSHA256, size: file.patchedSize)
            }
        }
    }

    func restore() throws {
        try mutationGuard?()
        let state = try check()
        if state == .original {
            if fileManager.fileExists(atPath: backupRoot.path) { try validateBackup() }
            return
        }
        try validateBackup()
        try transact(from: .patched, to: .original) { [self] incoming in
            for file in manifest.files {
                let original = try Self.safeURL(root: backupRoot, relativePath: file.relativePath)
                let destination = try Self.safeURL(root: incoming, relativePath: file.relativePath)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: original, to: destination)
                try Self.verify(destination, sha256: file.originalSHA256, size: file.originalSize)
            }
        }
    }

    private func validateManifest() throws {
        guard manifest.schemaVersion == 1,
              manifest.patchVersion == supportedPatchVersion,
              manifest.platform == "macOS",
              manifest.steamAppID == 4019220,
              manifest.steamBuildID == "25508059",
              manifest.gameVersion == "0.7.0",
              manifest.files.count == 4 else {
            throw PatchError.message("此補丁的版本說明不受支援，已停止。")
        }
        var resourcePaths = Set<String>()
        var deltaPaths = Set<String>()
        for file in manifest.files {
            try Self.validateRelativePath(file.relativePath)
            try Self.validateRelativePath(file.deltaPath)
            guard file.relativePath.hasPrefix("aa/"), file.deltaPath.hasPrefix("patches/"),
                  resourcePaths.insert(file.relativePath).inserted,
                  deltaPaths.insert(file.deltaPath).inserted,
                  file.originalSize > 0, file.patchedSize > 0, file.deltaSize > 0,
                  Self.validSHA(file.originalSHA256), Self.validSHA(file.patchedSHA256), Self.validSHA(file.deltaSHA256),
                  file.originalSHA256 != file.patchedSHA256 else {
                throw PatchError.message("補丁清單含有不安全路徑、重複項目或無效檔案資料，已停止。")
            }
            _ = try Self.safeURL(root: streamingRoot, relativePath: file.relativePath)
            _ = try Self.safeURL(root: packageRoot, relativePath: file.deltaPath)
        }
        guard resourcePaths == supportedResourcePaths else {
            throw PatchError.message("補丁清單的資源範圍不符，只能修改指定的四個語系資源。")
        }
    }

    private func validatePackage() throws {
        for file in manifest.files {
            let delta = try Self.safeURL(root: packageRoot, relativePath: file.deltaPath)
            try Self.verify(delta, sha256: file.deltaSHA256, size: file.deltaSize)
            let handle = try FileHandle(forReadingFrom: delta)
            defer { try? handle.close() }
            guard try handle.read(upToCount: 8) == Data("BSDIFF40".utf8) else {
                throw PatchError.message("差異補丁 \(file.deltaPath) 的格式錯誤，請重新下載完整補丁。")
            }
        }
    }

    private var expectedBackupFiles: [BackupFile] {
        manifest.files.map { BackupFile(relativePath: $0.relativePath, sha256: $0.originalSHA256, size: $0.originalSize) }
    }

    private func validateBackup() throws {
        try Self.requireDirectory(backupRoot)
        let canonicalBackup = backupRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalBackup == backupRoot.standardizedFileURL else {
            throw PatchError.message("原始備份資料夾是連結，已停止以保護備份。")
        }
        let recordURL = try Self.safeURL(root: backupRoot, relativePath: backupRecordName)
        try Self.requireRegularFile(recordURL)
        let record = try JSONDecoder().decode(BackupRecord.self, from: Data(contentsOf: recordURL))
        guard record.schemaVersion == 1,
              record.patchVersion == manifest.patchVersion,
              record.manifestSHA256 == manifestSHA256,
              record.files == expectedBackupFiles else {
            throw PatchError.message("原始備份的來源紀錄與此補丁不符，已停止；現有備份不會被覆蓋。")
        }
        for file in manifest.files {
            let original = try Self.safeURL(root: backupRoot, relativePath: file.relativePath)
            try Self.verify(original, sha256: file.originalSHA256, size: file.originalSize)
        }
    }

    private func ensureOriginalBackup() throws {
        if fileManager.fileExists(atPath: backupRoot.path) {
            try validateBackup()
            return
        }
        let temporary = backupRoot.deletingLastPathComponent().appendingPathComponent(backupFolderName + ".creating-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: temporary) }
        for file in manifest.files {
            let original = try Self.safeURL(root: streamingRoot, relativePath: file.relativePath)
            try Self.verify(original, sha256: file.originalSHA256, size: file.originalSize)
            let destination = try Self.safeURL(root: temporary, relativePath: file.relativePath)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: original, to: destination)
            try Self.verify(destination, sha256: file.originalSHA256, size: file.originalSize)
        }
        let record = BackupRecord(schemaVersion: 1, patchVersion: manifest.patchVersion, manifestSHA256: manifestSHA256, files: expectedBackupFiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: temporary.appendingPathComponent(backupRecordName), options: .atomic)
        try fileManager.moveItem(at: temporary, to: backupRoot)
        try validateBackup()
    }

    private func transact(from previousState: InstallationState, to desiredState: InstallationState, prepare: (URL) throws -> Void) throws {
        let staging = streamingRoot.appendingPathComponent(".dressmaker-zh-tw-staging-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var preserveStagingForRecovery = false
        defer { if !preserveStagingForRecovery { try? fileManager.removeItem(at: staging) } }
        let incoming = staging.appendingPathComponent("incoming", isDirectory: true)
        let rollback = staging.appendingPathComponent("rollback", isDirectory: true)
        try fileManager.createDirectory(at: incoming, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: rollback, withIntermediateDirectories: false)
        try prepare(incoming)
        guard try check() == previousState else {
            throw PatchError.message("準備補丁時遊戲資源發生變動，已停止。")
        }
        for file in manifest.files {
            let source = try Self.safeURL(root: streamingRoot, relativePath: file.relativePath)
            let snapshot = try Self.safeURL(root: rollback, relativePath: file.relativePath)
            try fileManager.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: snapshot)
            try verify(snapshot, file: file, state: previousState)
            let replacement = try Self.safeURL(root: incoming, relativePath: file.relativePath)
            try verify(replacement, file: file, state: desiredState)
            let attributes = try fileManager.attributesOfItem(atPath: source.path)
            if let permissions = attributes[.posixPermissions] {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: replacement.path)
            }
        }
        try mutationGuard?()
        try validateBackup()
        guard try check() == previousState else {
            throw PatchError.message("提交前遊戲資源發生變動，已停止。")
        }
        do {
            var replacements = 0
            for file in manifest.files {
                let target = try Self.safeURL(root: streamingRoot, relativePath: file.relativePath)
                try verify(target, file: file, state: previousState)
                let replacement = try Self.safeURL(root: incoming, relativePath: file.relativePath)
                _ = try fileManager.replaceItemAt(target, withItemAt: replacement)
                try verify(target, file: file, state: desiredState)
                replacements += 1
                #if INSTALLER_TESTING
                if testingFailureAfterReplacements == replacements {
                    throw PatchError.message("測試用提交中斷。")
                }
                #endif
            }
            guard try check() == desiredState else {
                throw PatchError.message("提交後檔案校驗失敗。")
            }
        } catch {
            let originalError = String(describing: error)
            var recoveryErrors: [String] = []
            for file in manifest.files {
                do {
                    let target = try Self.safeURL(root: streamingRoot, relativePath: file.relativePath)
                    let snapshot = try Self.safeURL(root: rollback, relativePath: file.relativePath)
                    try verify(snapshot, file: file, state: previousState)
                    let recoveryCopy = staging.appendingPathComponent("recovery-" + UUID().uuidString)
                    try fileManager.copyItem(at: snapshot, to: recoveryCopy)
                    if fileManager.fileExists(atPath: target.path) {
                        _ = try fileManager.replaceItemAt(target, withItemAt: recoveryCopy)
                    } else {
                        try fileManager.moveItem(at: recoveryCopy, to: target)
                    }
                    try verify(target, file: file, state: previousState)
                } catch {
                    recoveryErrors.append("\(file.relativePath): \(error)")
                }
            }
            if recoveryErrors.isEmpty {
                throw PatchError.message("套用未完成，四個遊戲檔案已全部還原至操作前狀態。原因：\(originalError)")
            }
            preserveStagingForRecovery = true
            throw PatchError.message("套用未完成，而且部分檔案無法自動復原。請保留原始備份與此復原資料夾：\(staging.path)\n\(recoveryErrors.joined(separator: "\n"))\n原因：\(originalError)")
        }
    }

    private func verify(_ url: URL, file: PatchFile, state: InstallationState) throws {
        switch state {
        case .original: try Self.verify(url, sha256: file.originalSHA256, size: file.originalSize)
        case .patched: try Self.verify(url, sha256: file.patchedSHA256, size: file.patchedSize)
        }
    }

    private func runBSPatch(original: URL, destination: URL, delta: URL, logRoot: URL) throws {
        let executable = URL(fileURLWithPath: "/usr/bin/bspatch")
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw PatchError.message("找不到 macOS 內建的 bspatch，無法套用補丁。")
        }
        let log = logRoot.appendingPathComponent("bspatch-" + UUID().uuidString + ".log")
        guard fileManager.createFile(atPath: log.path, contents: nil) else {
            throw PatchError.message("無法建立補丁處理紀錄。")
        }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close(); try? fileManager.removeItem(at: log) }
        let process = Process()
        process.executableURL = executable
        process.arguments = [original.path, destination.path, delta.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let contents = (try? Data(contentsOf: log)) ?? Data()
            let detail = String(data: contents.prefix(8192), encoding: .utf8) ?? ""
            throw PatchError.message("差異補丁處理失敗。\(detail)")
        }
    }

    private static func validateRelativePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PatchError.message("補丁含有不安全的相對路徑，已停止。")
        }
    }

    private static func safeURL(root: URL, relativePath: String) throws -> URL {
        try validateRelativePath(relativePath)
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let canonicalCandidate = candidate.resolvingSymlinksInPath()
        guard isContained(canonicalCandidate, in: canonicalRoot) else {
            throw PatchError.message("路徑連結超出預定資料夾，已停止。")
        }
        return candidate
    }

    private static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        return components.count > rootComponents.count && Array(components.prefix(rootComponents.count)) == rootComponents
    }

    private static func requireDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw PatchError.message("找不到必要的資料夾：\(url.lastPathComponent)")
        }
    }

    private static func requireRegularFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw PatchError.message("檔案不是一般檔案或是符號連結，已停止：\(url.lastPathComponent)")
        }
    }

    private static func validSHA(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func identity(_ url: URL) throws -> (sha256: String, size: Int64) {
        try requireRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
            bytes += Int64(data.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }

    private static func verify(_ url: URL, sha256: String, size: Int64) throws {
        let identity = try self.identity(url)
        guard identity.sha256 == sha256, identity.size == size else {
            throw PatchError.message("檔案校驗失敗：\(url.lastPathComponent)。未使用這個檔案繼續套用。")
        }
    }
}

#if !INSTALLER_TESTING
private enum InstallerUI {
    static func ensureGameStopped() throws {
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.Unity-Technologies.com.unity.template.urp-blank"
                || $0.localizedName?.lowercased() == "dressmaker"
                || $0.executableURL?.lastPathComponent.lowercased() == "dressmaker"
        }
        if running {
            throw PatchError.message("Dressmaker 仍在執行。請先在遊戲中儲存並離開，再關閉遊戲後重新操作；安裝器不會強制關閉遊戲。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "Dressmaker"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        if process.terminationReason == .exit && process.terminationStatus == 1 { return }
        if process.terminationReason == .exit && process.terminationStatus == 0 {
            throw PatchError.message("Dressmaker 仍在執行。請先儲存並關閉遊戲，再重新操作。")
        }
        throw PatchError.message("目前無法確認遊戲是否已關閉，已停止以保護遊戲進度。")
    }

    static func chooseGame(explicit: String?) throws -> URL {
        if let explicit = explicit {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        let fileManager = FileManager.default
        let steam = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        var libraries = [steam]
        let libraryFile = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let source = try? String(contentsOf: libraryFile, encoding: .utf8),
           let expression = try? NSRegularExpression(pattern: #""path"\s*"((?:\\.|[^"\\])*)""#) {
            let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in expression.matches(in: source, range: fullRange) {
                if let range = Range(match.range(at: 1), in: source) {
                    let value = String(source[range]).replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\\"", with: "\"")
                    if value.hasPrefix("/") { libraries.append(URL(fileURLWithPath: value, isDirectory: true)) }
                }
            }
        }
        var seen = Set<String>()
        let found = libraries.map {
            $0.appendingPathComponent("steamapps/common/Dressmaker/Dressmaker.app", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        }.filter {
            seen.insert($0.path).inserted && fileManager.fileExists(atPath: $0.path)
        }
        if found.count == 1 { return found[0] }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "選擇 Dressmaker 遊戲"
        panel.message = found.isEmpty ? "請選擇 Steam 安裝的 Dressmaker.app。" : "找到多個遊戲位置，請選擇要修改的 Dressmaker.app。"
        panel.prompt = "選擇遊戲"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedFileTypes = ["app"]
        panel.directoryURL = found.first?.deletingLastPathComponent() ?? steam.appendingPathComponent("steamapps/common", isDirectory: true)
        guard panel.runModal() == .OK, let selected = panel.url else {
            throw PatchError.message("已取消，未修改任何遊戲檔案。")
        }
        return selected
    }
}

@main
struct InstallerMain {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.contains("--help") || arguments.contains("-h") {
                print("Dressmaker 台灣繁體中文補丁 1.7\n用法：DressmakerPatch --install | --restore | --check [--game-app /路徑/Dressmaker.app]\n支援 Steam macOS 遊戲 0.7.0（Build 25508059）。請先儲存並關閉遊戲。")
                return
            }
            var mode: String?
            var explicitApp: String?
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--install", "--restore", "--check":
                    guard mode == nil else { throw PatchError.message("請一次只選一種操作。") }
                    mode = arguments[index]
                case "--game-app":
                    guard explicitApp == nil, index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                        throw PatchError.message("--game-app 後面需要 Dressmaker.app 的路徑。")
                    }
                    index += 1
                    explicitApp = arguments[index]
                default:
                    throw PatchError.message("未知的選項：\(arguments[index])。使用 --help 查看說明。")
                }
                index += 1
            }
            let operation = mode ?? "--install"
            if operation != "--check" { try InstallerUI.ensureGameStopped() }
            let selectedApp = try InstallerUI.chooseGame(explicit: explicitApp)
            guard let executable = Bundle.main.executableURL else {
                throw PatchError.message("無法找到安裝器所在資料夾。請將完整補丁解壓縮後再執行。")
            }
            let package = executable.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
            let engine = try Engine(packageRoot: package, gameApp: selectedApp)
            engine.mutationGuard = InstallerUI.ensureGameStopped
            print("Dressmaker 台灣繁體中文補丁 1.7")
            print("遊戲：\(engine.gameApp.path)")
            switch operation {
            case "--check":
                let state = try engine.check()
                print(state == .original ? "檢查完成：四個檔案都是支援的原版。" : "檢查完成：四個檔案都是 1.7 版繁體補丁。")
            case "--restore":
                try engine.restore()
                print("完成：四個資源檔案已恢復原版。存檔不會被修改。")
            default:
                try engine.install()
                print("完成：1.7 版台灣繁體中文補丁已套用。可重新開啟 Steam 遊戲。")
                print("原始備份：\(engine.backupRoot.path)")
            }
        } catch {
            fputs("\n未完成：\(error)\n", stderr)
            exit(1)
        }
    }
}
#endif
