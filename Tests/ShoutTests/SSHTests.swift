//
// SSHTests.swift
// ShoutTests
//
//  Created by Jake Heiser on 3/4/18.
//

import Shout
import XCTest
import CryptoKit

struct ShoutServer {
    static let host = "127.0.0.1"
    static let username = NSUserName()
    static let password = ""
	static let agentAuth = SSHAgent()
	static let sshKeyAuth = SSHKey(privateKey: "~/.ssh/id_rsa")
    static let passwordAuth = SSHPassword(password)
    
    static let authMethod = sshKeyAuth
}

class ShoutTests: XCTestCase {
    
    func testCapture() throws {
        let ssh = try SSH(host: ShoutServer.host)
        try ssh.authenticate(username: ShoutServer.username, authMethod: ShoutServer.authMethod)
        
        let (result, contents) = try ssh.capture("ls /")
        XCTAssertEqual(result, 0)
        XCTAssertTrue(contents.contains("bin"))
    }

    func testConnect() throws {
        try SSH.connect(host: ShoutServer.host, username: ShoutServer.username, authMethod: ShoutServer.authMethod) { (ssh) in
            let (result, contents) = try ssh.capture("ls /")
            XCTAssertEqual(result, 0)
            XCTAssertTrue(contents.contains("bin"))
        }
    }

    func testSendFile() throws {
        try SSH.connect(host: ShoutServer.host, username: ShoutServer.username, authMethod: ShoutServer.authMethod) { (ssh) in
            try ssh.sendFile(localURL: URL(fileURLWithPath: String(#file)), remotePath: "/tmp/shout_upload_test.swift")
            
            let (status, contents) = try ssh.capture("cat /tmp/shout_upload_test.swift")
            XCTAssertEqual(status, 0)
            XCTAssertEqual(contents.components(separatedBy: "\n")[1], "// SSHTests.swift")
            
            XCTAssertEqual(try ssh.execute("rm /tmp/shout_upload_test.swift", silent: false), 0)
        }
    }

	func testSendBigFile() throws {
        // Create a 20 MB temporary file locally
        let sizeInBytes = 20 * 1024 * 1024 // 20 MB
        let tempDir = FileManager.default.temporaryDirectory
        let localTempURL = tempDir.appendingPathComponent("shout_big_upload_test.bin")
        // Ensure any previous file is removed
        try? FileManager.default.removeItem(at: localTempURL)
        // Fill the file with repeating Lorem ipsum text instead of zeros
        let lorem = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.\n"
        let pattern = Array(lorem.utf8)
        var buffer = [UInt8]()
        buffer.reserveCapacity(sizeInBytes)
        while buffer.count + pattern.count <= sizeInBytes {
            buffer.append(contentsOf: pattern)
        }
        // Append remaining bytes to reach exact size
        let remaining = sizeInBytes - buffer.count
        if remaining > 0 {
            buffer.append(contentsOf: pattern.prefix(remaining))
        }
        let data = Data(buffer)
        try data.write(to: localTempURL, options: .atomic)
        // Verify local size
        let attrs = try FileManager.default.attributesOfItem(atPath: localTempURL.path)
        let localSize = (attrs[.size] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(localSize, sizeInBytes)
        // Always remove the local temp file at the end
        defer { try? FileManager.default.removeItem(at: localTempURL) }

        let remotePath = "/tmp/shout_upload_test_big.bin"
        try SSH.connect(host: ShoutServer.host, username: ShoutServer.username, authMethod: ShoutServer.authMethod) { ssh in
            // Upload the big file
            try ssh.sendFile(localURL: localTempURL, remotePath: remotePath)

            // Verify on remote: file size matches 20 MB
            // Try stat first; fall back to wc -c if needed
            let (status, output) = try ssh.capture("(stat -f%z '\(remotePath)' 2>/dev/null || wc -c < '\(remotePath)')")
            if status != 0 {
                let (status2, output2) = try ssh.capture("stat -f%z '\(remotePath)'")
                XCTAssertEqual(status2, 0)
                XCTAssertEqual(Int(output2.trimmingCharacters(in: .whitespacesAndNewlines)), sizeInBytes)
            } else {
                XCTAssertEqual(Int(output.trimmingCharacters(in: .whitespacesAndNewlines)), sizeInBytes)
            }

            // Compute and compare SHA-256 to ensure files are identical
            let localData = try Data(contentsOf: localTempURL)
            let localHash = SHA256.hash(data: localData).map { String(format: "%02x", $0) }.joined()

            let (hashStatus, hashOutput) = try ssh.capture("shasum -a 256 '" + remotePath + "' | awk '{print $1}'")
            XCTAssertEqual(hashStatus, 0)
            let remoteHash = hashOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(localHash, remoteHash, "Local and remote file hashes should match")

            // Clean up remote file
            XCTAssertEqual(try ssh.execute("rm -f '\(remotePath)'", silent: false), 0)
        }
	}
}

