//
//  main.swift
//  PearcleanerHelper
//
//  Created by Alin Lupascu on 3/14/25.
//

import Foundation
import ObjectiveC

@objc(HelperToolProtocol)
public protocol HelperToolProtocol {
    func ping(withReply reply: @escaping (Bool, String) -> Void)
    func moveItem(atPath sourcePath: String, toPath destinationPath: String, withReply reply: @escaping (Bool, String) -> Void)
    func runCommand(command: String, withReply reply: @escaping (Bool, String) -> Void)
    func runThinning(atPath: String, withReply reply: @escaping (Bool, String) -> Void)
    func runBundleThinning(bundlePath: String, withReply reply: @escaping (Bool, String, [String: UInt64]) -> Void)
}

// XPC Communication setup
class HelperToolDelegate: NSObject, NSXPCListenerDelegate, HelperToolProtocol {
    private var activeConnections = Set<NSXPCConnection>()
    private let clientCodeSigningRequirement: String
    
    override init() {
        do {
            let teamIdentifier = try CodesignCheck.codeSigningTeamIdentifierForSelf()
            clientCodeSigningRequirement = "anchor apple generic and identifier \"\(OnglaiIdentity.bundleIdentifier)\" and certificate leaf[subject.OU] = \(teamIdentifier)"
        } catch {
            fatalError("Unable to establish the helper client identity: \(error)")
        }
        super.init()
    }
    

    
    // Accept new XPC connections by setting up the exported interface and object.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard isValidClient(connection: newConnection) else {
            print("❌ Rejected connection from unauthorized client")
            return false
        }
        // Kernel-enforced per-message requirement: caller must be the Onglai
        // main app signed by the same team as this helper. Deriving the team
        // from our own signature keeps Debug and Developer ID builds aligned
        // without trusting a source-code constant or a caller-provided value.
        newConnection.setCodeSigningRequirement(clientCodeSigningRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: HelperToolProtocol.self)
        newConnection.exportedObject = self
        newConnection.invalidationHandler = { [weak self] in
            self?.activeConnections.remove(newConnection)
            if self?.activeConnections.isEmpty == true {
                exit(0) // Exit when no active connections remain
            }
        }
        activeConnections.insert(newConnection)
        newConnection.resume()
        return true
    }

    func ping(withReply reply: @escaping (Bool, String) -> Void) {
        reply(true, "pong")
    }

    func moveItem(atPath sourcePath: String, toPath destinationPath: String, withReply reply: @escaping (Bool, String) -> Void) {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let destinationURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
        let sourceParent = sourceURL.deletingLastPathComponent()
        let destinationParent = destinationURL.deletingLastPathComponent()
        let protectedPaths: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users",
            "/bin", "/etc", "/private", "/sbin", "/usr", "/var"
        ]

        guard sourceURL.path.hasPrefix("/"),
              destinationURL.path.hasPrefix("/"),
              sourceParent == destinationParent,
              sourceURL != destinationURL,
              !protectedPaths.contains(sourceURL.path),
              !protectedPaths.contains(destinationURL.path),
              fileManager.fileExists(atPath: sourceURL.path),
              !fileManager.fileExists(atPath: destinationURL.path) else {
            reply(false, "The requested rename is not permitted")
            return
        }

        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            reply(true, "Success")
        } catch {
            reply(false, error.localizedDescription)
        }
    }
    
    // Execute the shell command and reply with output.
    func runCommand(command: String, withReply reply: @escaping (Bool, String) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            reply(false, "Failed to run command: \(error.localizedDescription)")
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let success = (process.terminationStatus == 0) // Check if process exited successfully
        reply(success, output.isEmpty ? "No output" : output)
    }
    
    // Execute app lipo using privileges for apps owned by root
    func runThinning(atPath: String, withReply reply: @escaping (Bool, String) -> Void) {
        let success = thinBinaryUsingMachO(executablePath: atPath)
        reply(success, success ? "Success" : "Failed")
    }
    
    func runBundleThinning(bundlePath: String, withReply reply: @escaping (Bool, String, [String: UInt64]) -> Void) {
        let bundleURL = URL(fileURLWithPath: bundlePath)
        let result = thinAppBundle(at: bundleURL)
        
        let success = result.0
        let message = success ? "Bundle thinning completed successfully" : "Bundle thinning failed"
        let sizes = result.1 ?? [:]
        
        reply(success, message, sizes)
    }

    // Check that the codesigning matches between the main app and the helper app
    private func isValidClient(connection: NSXPCConnection) -> Bool {
        do {
            return try CodesignCheck.codeSigningMatches(pid: connection.processIdentifier)
        } catch {
            print("Helper code signing check failed with error: \(error)")
            return false
        }
    }
}

// Set up and start the XPC listener.
let delegate = HelperToolDelegate()
let listener = NSXPCListener(machServiceName: OnglaiIdentity.helperIdentifier)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
