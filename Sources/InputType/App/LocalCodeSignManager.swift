import Cocoa
import Foundation

final class LocalCodeSignManager {
    static let shared = LocalCodeSignManager()
    static let certificateName = "PrimeType Local Sign"

    private init() {}

    func firstIdentitySHA1() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-identity", "-v", "-p", "codesigning"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            for line in output.split(separator: "\n") {
                if line.contains("\"\(Self.certificateName)\"") {
                    let tokens = line.split(whereSeparator: { $0.isWhitespace })
                    // Format: "  1) <40-hex-SHA1> \"PrimeType Local Sign\""
                    if tokens.count >= 2, tokens[1].count == 40 {
                        return String(tokens[1])
                    }
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    func isCertificateConfigured() -> Bool {
        firstIdentitySHA1() != nil
    }

    func setupCertificateAndSignApp() async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let tmpDir = fm.temporaryDirectory.appendingPathComponent("PrimeTypeSign-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmpDir) }

            let cfgURL = tmpDir.appendingPathComponent("cert.cfg")
            let keyURL = tmpDir.appendingPathComponent("cert.key")
            let crtURL = tmpDir.appendingPathComponent("cert.crt")
            let p12URL = tmpDir.appendingPathComponent("cert.p12")

            let opensslConfig = """
            [req]
            distinguished_name = req_distinguished_name
            x509_extensions = v3_codesign
            prompt = no

            [req_distinguished_name]
            CN = \(Self.certificateName)

            [v3_codesign]
            keyUsage = critical, digitalSignature
            extendedKeyUsage = critical, codeSigning
            basicConstraints = critical, CA:false
            """
            try opensslConfig.write(to: cfgURL, atomically: true, encoding: .utf8)

            // 1. Generate 10-year self-signed code signing certificate
            try Self.run("/usr/bin/openssl", [
                "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", keyURL.path,
                "-out", crtURL.path,
                "-days", "3650",
                "-config", cfgURL.path
            ])

            let pass = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            try Self.run("/usr/bin/openssl", [
                "pkcs12", "-export",
                "-out", p12URL.path,
                "-inkey", keyURL.path,
                "-in", crtURL.path,
                "-passout", "pass:\(pass)"
            ])

            let loginKeychain = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Keychains/login.keychain-db").path

            // Clean any previous duplicate entries first
            Self.deleteAllMatchingCertificates(in: loginKeychain)

            // 2. Import into login keychain and trust for code signing (macOS will prompt once for confirmation)
            try Self.run("/usr/bin/security", [
                "import", p12URL.path,
                "-k", loginKeychain,
                "-P", pass,
                "-T", "/usr/bin/codesign"
            ])

            try Self.run("/usr/bin/security", [
                "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign",
                "-k", loginKeychain,
                crtURL.path
            ])

            // 3. Re-sign installed PrimeType.app immediately
            try Self.resignInstalledAppIfConfigured()

            // 4. Clear stale Accessibility TCC record so the restarted process prompts cleanly once for the new certificate
            _ = try? Self.run("/usr/bin/tccutil", [
                "reset", "Accessibility",
                "com.lumocore.inputmethod.PrimeType"
            ])
        }.value

        await MainActor.run {
            InputSettings.shared.lastLaunchedVersion = "__local_resigned__"
        }
    }

    func removeCertificate() async throws {
        try await Task.detached(priority: .userInitiated) {
            let loginKeychain = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Keychains/login.keychain-db").path
            Self.deleteAllMatchingCertificates(in: loginKeychain)
        }.value
    }

    private static func deleteAllMatchingCertificates(in keychain: String) {
        for _ in 0..<8 {
            guard let sha1 = shared.firstIdentitySHA1() else { break }
            do {
                try run("/usr/bin/security", ["delete-certificate", "-t", "-Z", sha1, keychain])
            } catch {
                _ = try? run("/usr/bin/security", ["delete-certificate", "-Z", sha1, keychain])
                break
            }
        }
        for _ in 0..<4 {
            do {
                try run("/usr/bin/security", ["delete-certificate", "-t", "-c", Self.certificateName, keychain])
            } catch {
                break
            }
        }
    }

    static func signAppBundle(at appPath: String) throws {
        guard let sha1 = shared.firstIdentitySHA1() else { return }
        guard FileManager.default.fileExists(atPath: appPath) else { return }

        let fm = FileManager.default
        if fm.isWritableFile(atPath: appPath) {
            try run("/usr/bin/codesign", ["--force", "--deep", "--sign", sha1, appPath])
        } else {
            let cmd = "/usr/bin/codesign --force --deep --sign \"\(sha1)\" \"\(appPath)\""
            let escaped = cmd
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            try run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        }
    }

    static func resignInstalledAppIfConfigured() throws {
        try signAppBundle(at: "/Library/Input Methods/PrimeType.app")
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "LocalCodeSignManager", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: errText.isEmpty ? "操作失败（退出码 \(proc.terminationStatus)）" : errText
            ])
        }
    }
}
