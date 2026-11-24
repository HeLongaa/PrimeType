import Cocoa
import Foundation

final class LocalCodeSignManager {
    static let shared = LocalCodeSignManager()
    static let certificateName = "PrimeType Local Sign"

    private init() {}

    func isCertificateConfigured() -> Bool {
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
            return output.contains("\"\(Self.certificateName)\"")
        } catch {
            return false
        }
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
                "-passout", "pass:\(pass)",
                "-legacy"
            ])

            let loginKeychain = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Keychains/login.keychain-db").path

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
        }.value
    }

    func removeCertificate() async throws {
        try await Task.detached(priority: .userInitiated) {
            let loginKeychain = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Keychains/login.keychain-db").path
            try Self.run("/usr/bin/security", [
                "delete-certificate", "-c", Self.certificateName, loginKeychain
            ])
        }.value
    }

    static func resignInstalledAppIfConfigured() throws {
        guard shared.isCertificateConfigured() else { return }
        let appPath = "/Library/Input Methods/PrimeType.app"
        guard FileManager.default.fileExists(atPath: appPath) else { return }

        let fm = FileManager.default
        if fm.isWritableFile(atPath: appPath) {
            try run("/usr/bin/codesign", ["--force", "--deep", "--sign", certificateName, appPath])
        } else {
            let cmd = "/usr/bin/codesign --force --deep --sign \"\(certificateName)\" \"\(appPath)\""
            let escaped = cmd
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            try run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        }
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
