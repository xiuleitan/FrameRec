import Foundation
import Security

// Keep generated passwords inside this process rather than command-line args.
// This dedicated keychain never becomes a system-wide trusted certificate store.
func check(_ status: OSStatus, _ operation: String) throws {
    guard status == errSecSuccess else {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        throw NSError(domain: "FrameRecSigning", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(operation): \(message)"])
    }
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw NSError(domain: "FrameRecSigning", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: signing-keychain <signing directory>"])
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let keychainURL = directory.appendingPathComponent("identity.keychain-db")
    let password = try String(contentsOf: directory.appendingPathComponent("password"), encoding: .utf8)
    var keychain: SecKeychain?
    if FileManager.default.fileExists(atPath: keychainURL.path) {
        try check(SecKeychainOpen(keychainURL.path, &keychain), "Open local signing keychain")
    } else {
        let status = password.withCString { pointer in
            SecKeychainCreate(keychainURL.path, UInt32(password.utf8.count), pointer, false, nil, &keychain)
        }
        try check(status, "Create local signing keychain")
    }
    guard let keychain else { throw NSError(domain: "FrameRecSigning", code: 2) }
    try check(password.withCString { SecKeychainUnlock(keychain, UInt32(password.utf8.count), $0, true) }, "Unlock local signing keychain")

    let p12 = directory.appendingPathComponent("pending-identity.p12")
    if FileManager.default.fileExists(atPath: p12.path) {
        var application: SecTrustedApplication?
        try check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &application), "Authorize the system signing tool")
        var access: SecAccess?
        try check(SecAccessCreate("FrameRec local code signing" as CFString, [application!] as CFArray, &access), "Create signing key access policy")
        var items: CFArray?
        let options: [CFString: Any] = [
            kSecImportExportPassphrase: password,
            kSecImportExportKeychain: keychain,
            kSecImportExportAccess: access!,
        ]
        try check(SecPKCS12Import(try Data(contentsOf: p12) as CFData, options as CFDictionary, &items), "Import local signing identity")
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
