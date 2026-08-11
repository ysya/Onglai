//
//  Lipo.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 4/10/25.
//

import Foundation


// Helper structs for Mach-O parsing
public struct FatHeader {
    public let magic: UInt32
    public let numArchitectures: UInt32
    
    public init(magic: UInt32, numArchitectures: UInt32) {
        self.magic = magic
        self.numArchitectures = numArchitectures
    }
}

public struct FatArch {
    public let cpuType: UInt32
    public let cpuSubtype: UInt32
    public let offset: UInt32
    public let size: UInt32
    public let align: UInt32
    
    public init(cpuType: UInt32, cpuSubtype: UInt32, offset: UInt32, size: UInt32, align: UInt32) {
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
        self.offset = offset
        self.size = size
        self.align = align
    }
}

private let cpuTypeARM64: UInt32 = 0x0100000c
private let cpuTypeX86_64: UInt32 = 0x01000007
private let fatMagic: UInt32 = 0xcafebabe

private func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var bigEndianValue = value.bigEndian
    withUnsafeBytes(of: &bigEndianValue) { data.append(contentsOf: $0) }
}

private func parseFatArchitectures(from data: Data) -> [FatArch]? {
    guard data.count >= 8 else { return nil }

    let header = data.prefix(8).withUnsafeBytes { ptr in
        FatHeader(
            magic: ptr.load(fromByteOffset: 0, as: UInt32.self).bigEndian,
            numArchitectures: ptr.load(fromByteOffset: 4, as: UInt32.self).bigEndian
        )
    }

    guard header.magic == fatMagic,
          header.numArchitectures > 0,
          header.numArchitectures < 100 else {
        return nil
    }

    let headersSize = Int(header.numArchitectures) * 20
    guard data.count >= 8 + headersSize else { return nil }

    var architectures: [FatArch] = []
    for index in 0..<Int(header.numArchitectures) {
        let headerOffset = 8 + (index * 20)
        let arch = data[headerOffset..<(headerOffset + 20)].withUnsafeBytes { ptr in
            FatArch(
                cpuType: ptr.load(fromByteOffset: 0, as: UInt32.self).bigEndian,
                cpuSubtype: ptr.load(fromByteOffset: 4, as: UInt32.self).bigEndian,
                offset: ptr.load(fromByteOffset: 8, as: UInt32.self).bigEndian,
                size: ptr.load(fromByteOffset: 12, as: UInt32.self).bigEndian,
                align: ptr.load(fromByteOffset: 16, as: UInt32.self).bigEndian
            )
        }

        let sliceStart = Int(arch.offset)
        let sliceEnd = sliceStart + Int(arch.size)
        guard sliceStart >= 0, sliceEnd >= sliceStart, sliceEnd <= data.count else {
            return nil
        }
        architectures.append(arch)
    }
    return architectures
}

/// Removes foreign CPU families from a fat Mach-O while preserving every slice
/// for the current family. In particular, arm64 and arm64e have the same CPU
/// type and different subtypes, so both must survive thinning.
///
/// Returns nil when the input is malformed, has no requested architecture, or
/// already contains only the requested CPU family.
func thinFatBinaryData(_ data: Data, keepingCPUType targetCPUType: UInt32) -> Data? {
    guard let architectures = parseFatArchitectures(from: data) else { return nil }

    let keptArchitectures = architectures.filter { $0.cpuType == targetCPUType }
    guard !keptArchitectures.isEmpty, keptArchitectures.count < architectures.count else {
        return nil
    }

    // A single surviving slice can become a normal thin Mach-O.
    if keptArchitectures.count == 1, let arch = keptArchitectures.first {
        let start = Int(arch.offset)
        let end = start + Int(arch.size)
        return data.subdata(in: start..<end)
    }

    // Multiple subtypes from the same family (for example arm64 + arm64e)
    // must remain a fat binary. Rebuild the table and compact away foreign
    // slices while retaining each subtype, alignment and payload unchanged.
    var rebuilt = Data()
    appendBigEndian(fatMagic, to: &rebuilt)
    appendBigEndian(UInt32(keptArchitectures.count), to: &rebuilt)

    let headerSize = 8 + keptArchitectures.count * 20
    rebuilt.append(Data(repeating: 0, count: keptArchitectures.count * 20))

    var rebuiltArchitectures: [FatArch] = []
    for arch in keptArchitectures {
        // Mach-O slices normally use page-size alignment. Reject implausibly
        // large exponents instead of allocating a hostile amount of padding.
        guard arch.align <= 24 else { return nil }
        let alignment = 1 << Int(arch.align)
        let padding = (alignment - (rebuilt.count % alignment)) % alignment
        rebuilt.append(Data(repeating: 0, count: padding))

        guard rebuilt.count <= Int(UInt32.max) else { return nil }
        let newOffset = UInt32(rebuilt.count)
        let start = Int(arch.offset)
        let end = start + Int(arch.size)
        rebuilt.append(data.subdata(in: start..<end))

        rebuiltArchitectures.append(
            FatArch(
                cpuType: arch.cpuType,
                cpuSubtype: arch.cpuSubtype,
                offset: newOffset,
                size: arch.size,
                align: arch.align
            )
        )
    }

    guard rebuilt.count >= headerSize else { return nil }
    var headerTable = Data()
    for arch in rebuiltArchitectures {
        appendBigEndian(arch.cpuType, to: &headerTable)
        appendBigEndian(arch.cpuSubtype, to: &headerTable)
        appendBigEndian(arch.offset, to: &headerTable)
        appendBigEndian(arch.size, to: &headerTable)
        appendBigEndian(arch.align, to: &headerTable)
    }
    rebuilt.replaceSubrange(8..<headerSize, with: headerTable)
    return rebuilt
}

// Function to thin an entire app bundle with size tracking
public func thinAppBundle(at bundlePath: URL, dryRun: Bool = false) -> (Bool, [String: UInt64]?) {
    // Get the total bundle size before thinning
    let preTotalSize = UInt64(totalSizeOnDisk(for: bundlePath))
    
    let result = recursivelyThinBundle(at: bundlePath, dryRun: dryRun)
    
    if result.success {
        if dryRun {
            // For dry run, calculate estimated post-size based on binary savings
            let binarySavings = result.sizes?["binarySavings"] ?? 0
            let estimatedPostSize = preTotalSize > binarySavings ? preTotalSize - binarySavings : preTotalSize
            let sizes = ["pre": preTotalSize, "post": estimatedPostSize]
            return (true, sizes)
        } else {
            // For real thinning, get the actual bundle size after thinning
            let postTotalSize = UInt64(totalSizeOnDisk(for: bundlePath))
            let sizes = ["pre": preTotalSize, "post": postTotalSize]
            return (true, sizes)
        }
    } else {
        return (result.success, result.sizes)
    }
}

// Recursively thin all binaries in a bundle
func recursivelyThinBundle(at path: URL, dryRun: Bool = false) -> (success: Bool, sizes: [String: UInt64]?) {
    let fileManager = FileManager.default

    guard let enumerator = fileManager.enumerator(at: path,
                                                  includingPropertiesForKeys: [.isDirectoryKey, .isExecutableKey],
                                                  options: [.skipsHiddenFiles]) else {
        print("Bundle Error: Could not enumerate bundle contents")
        return (false, nil)
    }

    var processedFiles: [String] = []
    var skippedFiles: [String] = []
    var totalPreSize: UInt64 = 0
    var totalPostSize: UInt64 = 0

    // Collect all file URLs first to avoid keeping enumerator handles open
    var candidateFiles: [URL] = []
    autoreleasepool {
        for case let fileURL as URL in enumerator {
            autoreleasepool {
                // Skip directories early
                let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
                if resourceValues?.isDirectory == true {
                    return
                }
                candidateFiles.append(fileURL)
            }
        }
    }

    // Process files in batches to limit memory and file descriptor usage
    let batchSize = 50
    for batchStart in stride(from: 0, to: candidateFiles.count, by: batchSize) {
        autoreleasepool {
            let batchEnd = min(batchStart + batchSize, candidateFiles.count)
            let batch = Array(candidateFiles[batchStart..<batchEnd])

            for fileURL in batch {
                autoreleasepool {
                    if shouldThinFile(fileURL) {
                        // Get file size before thinning
                        if let preAttributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                           let preSize = preAttributes[.size] as? UInt64 {

                            if dryRun {
                                // For dry run, calculate potential savings without modifying files
                                do {
                                    if let sizes = try getArchitectureSliceSizes(from: fileURL.path) {
                                        totalPreSize += preSize
#if arch(arm64)
                                        let removedSize = UInt64(sizes.intel)
#else
                                        let removedSize = UInt64(sizes.arm)
#endif
                                        let estimatedPostSize = preSize > removedSize ? preSize - removedSize : preSize
                                        totalPostSize += estimatedPostSize
                                        processedFiles.append(fileURL.path)
                                    } else {
                                        skippedFiles.append(fileURL.path)
                                    }
                                } catch {
                                    skippedFiles.append(fileURL.path)
                                }
                            } else {
                                // Real thinning
                                if thinBinaryUsingMachO(executablePath: fileURL.path) {
                                    // Get file size after thinning
                                    if let postAttributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                                       let postSize = postAttributes[.size] as? UInt64 {
                                        totalPreSize += preSize
                                        totalPostSize += postSize
                                    }
                                    processedFiles.append(fileURL.path)
                                } else {
                                    skippedFiles.append(fileURL.path)
                                }
                            }
                        } else {
                            skippedFiles.append(fileURL.path)
                        }
                    }
                }
            }
        }
    }

    let success = processedFiles.count > 0 || (processedFiles.count == 0 && skippedFiles.count >= 0)
    var sizes: [String: UInt64]? = nil

    if totalPreSize > 0 {
        if dryRun {
            // For dry run, include the binary savings calculation
            let binarySavings = totalPreSize > totalPostSize ? totalPreSize - totalPostSize : 0
            sizes = ["pre": totalPreSize, "post": totalPostSize, "binarySavings": binarySavings]
        } else {
            // For real thinning, just include pre/post
            sizes = ["pre": totalPreSize, "post": totalPostSize]
        }
    }

    return (success, sizes)
}

// Determine if a file should be thinned
func shouldThinFile(_ url: URL) -> Bool {
    // Check if it's an executable binary
    return isExecutableBinary(url)
}

// Find the app bundle path by traversing up the directory tree
func findAppBundlePath(from url: URL) -> URL {
    var currentURL = url
    
    // Keep going up until we find a .app bundle or reach the root
    while currentURL.path != "/" {
        if currentURL.pathExtension == "app" {
            return currentURL
        }
        currentURL = currentURL.deletingLastPathComponent()
    }
    
    // Fallback: assume it's a traditional app bundle structure
    var fallbackURL = url
    while fallbackURL.path != "/" && !fallbackURL.path.hasSuffix(".app") {
        fallbackURL = fallbackURL.deletingLastPathComponent()
    }
    
    return fallbackURL
}

// Check if a file is an executable binary
public func isExecutableBinary(_ url: URL) -> Bool {
    // First check file extension for known binary types
    let pathExtension = url.pathExtension.lowercased()
    let knownBinaryExtensions = ["dylib", "so", "bundle"]

    // If it's a known binary extension, assume it's a binary (faster than reading file)
    if knownBinaryExtensions.contains(pathExtension) {
        return true
    }

    // Special handling for bundle structures that might contain binaries
    // (.appex, .xpc, .framework are bundles, but we want to check their executables inside)
    let bundleExtensions = ["appex", "xpc", "framework"]
    if bundleExtensions.contains(pathExtension) {
        // These are bundles - the enumerator will traverse into them
        // and find the actual executable inside
        return false
    }

    // For other files, check magic numbers - use FileHandle to read only 4 bytes
    guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
        return false
    }

    defer {
        try? fileHandle.close()
    }

    guard let magicData = try? fileHandle.read(upToCount: 4), magicData.count == 4 else {
        return false
    }

    let magic = magicData.withUnsafeBytes { $0.load(as: UInt32.self) }
    let FAT_MAGIC: UInt32 = 0xcafebabe
    let FAT_MAGIC_SWAPPED: UInt32 = 0xbebafeca // Little-endian version
    let MH_MAGIC_64: UInt32 = 0xfeedfacf
    let MH_CIGAM_64: UInt32 = 0xcffaedfe
    let MH_MAGIC: UInt32 = 0xfeedface
    let MH_CIGAM: UInt32 = 0xcefaedfe

    return magic == FAT_MAGIC || magic == FAT_MAGIC_SWAPPED ||
           magic == MH_MAGIC_64 || magic == MH_CIGAM_64 ||
           magic == MH_MAGIC || magic == MH_CIGAM
}

// Helper function to thin a binary using Mach-O APIs
public func thinBinaryUsingMachO(executablePath: String) -> Bool {
    // Keep the entire native CPU family. arm64 and arm64e share CPU_TYPE_ARM64,
    // so filtering by CPU type retains both slices.
    let targetCPUType: UInt32
#if arch(arm64)
    targetCPUType = cpuTypeARM64
#else
    targetCPUType = cpuTypeX86_64
#endif

    // Find the app bundle path by searching up the directory tree
    let executableURL = URL(fileURLWithPath: executablePath)
    let appBundlePath = findAppBundlePath(from: executableURL)

    return autoreleasepool {
        do {
            // Use FileHandle instead of loading entire file into memory
            guard let fileHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: executablePath)) else {
                return false
            }
            defer {
                try? fileHandle.close()
            }

            try? fileHandle.seek(toOffset: 0)
            guard let fileData = try? fileHandle.readToEnd(),
                  let thinnedData = thinFatBinaryData(fileData, keepingCPUType: targetCPUType) else {
                return false
            }

            try thinnedData.write(to: executableURL)

            // Update file timestamp to refresh Finder bundle size right away
            if !appBundlePath.path.isEmpty && appBundlePath.path != "/" {
                try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: appBundlePath.path)
            }

            return true

        } catch {
            print("Mach-O Error: \(error)")
            return false
        }
    }
}

// Get the size of different architecture slices in a Mach-O binary
public func getArchitectureSliceSizes(from executablePath: String) throws -> (arm: UInt32, intel: UInt32, full: UInt32)? {
    guard !executablePath.isEmpty else {
        throw NSError(domain: "LipoError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty executable path"])
    }

    return try autoreleasepool {
        let fileURL = URL(fileURLWithPath: executablePath)

        // Use FileHandle to read only necessary bytes
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            throw NSError(domain: "LipoError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not open file"])
        }
        defer {
            try? fileHandle.close()
        }

        // Get file size efficiently using FileHandle
        let fileSize = fileHandle.seekToEndOfFile()
        let fullSize = UInt32(min(fileSize, UInt64(UInt32.max)))

        // Seek back to beginning to read header
        try fileHandle.seek(toOffset: 0)

        guard let headerData = try? fileHandle.read(upToCount: 8), headerData.count >= 8 else {
            throw NSError(domain: "LipoError", code: 3, userInfo: [NSLocalizedDescriptionKey: "File too small to contain valid header"])
        }

        let FAT_MAGIC: UInt32 = 0xcafebabe

        let header = try headerData.withUnsafeBytes { ptr -> FatHeader in
            guard ptr.count >= 8 else {
                throw NSError(domain: "LipoError", code: 4, userInfo: [NSLocalizedDescriptionKey: "Insufficient data for header"])
            }
            return FatHeader(
                magic: ptr.load(fromByteOffset: 0, as: UInt32.self).bigEndian,
                numArchitectures: ptr.load(fromByteOffset: 4, as: UInt32.self).bigEndian
            )
        }

        var armSize: UInt32 = 0
        var intelSize: UInt32 = 0

        if header.magic == FAT_MAGIC {
            guard header.numArchitectures > 0 && header.numArchitectures < 100 else {
                throw NSError(domain: "LipoError", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid number of architectures"])
            }

            // Read all architecture headers at once (20 bytes each)
            let archDataSize = Int(header.numArchitectures) * 20
            guard let allArchData = try? fileHandle.read(upToCount: archDataSize),
                  allArchData.count == archDataSize else {
                throw NSError(domain: "LipoError", code: 6, userInfo: [NSLocalizedDescriptionKey: "Could not read architecture headers"])
            }

            var offset = 0
            for _ in 0..<header.numArchitectures {
                let arch = allArchData[offset..<(offset + 20)].withUnsafeBytes { ptr -> FatArch in
                    FatArch(
                        cpuType: ptr.load(fromByteOffset: 0, as: UInt32.self).bigEndian,
                        cpuSubtype: ptr.load(fromByteOffset: 4, as: UInt32.self).bigEndian,
                        offset: ptr.load(fromByteOffset: 8, as: UInt32.self).bigEndian,
                        size: ptr.load(fromByteOffset: 12, as: UInt32.self).bigEndian,
                        align: ptr.load(fromByteOffset: 16, as: UInt32.self).bigEndian
                    )
                }

                if arch.cpuType == cpuTypeARM64 {
                    armSize = armSize.addingReportingOverflow(arch.size).overflow
                        ? UInt32.max
                        : armSize + arch.size
                } else if arch.cpuType == cpuTypeX86_64 {
                    intelSize = intelSize.addingReportingOverflow(arch.size).overflow
                        ? UInt32.max
                        : intelSize + arch.size
                }
                offset += 20
            }
        } else {
            // For a lipo'd binary, assume the whole file is the slice.
            // Read bytes 4-8 to check CPU type
            try? fileHandle.seek(toOffset: 4)
            guard let cpuTypeData = try? fileHandle.read(upToCount: 4), cpuTypeData.count == 4 else {
                return (arm: 0, intel: 0, full: fullSize)
            }

            let cpuType = cpuTypeData.withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            }
            if cpuType == cpuTypeARM64 {
                armSize = fullSize
            } else if cpuType == cpuTypeX86_64 {
                intelSize = fullSize
            }
        }

        return (arm: armSize, intel: intelSize, full: fullSize)
    }
}



// Get size of files (logical size - matches Finder)
public func totalSizeOnDisk(for paths: [URL]) -> Int64 {
    let fileManager = FileManager.default
    var totalFileSize: Int64 = 0

    for url in paths {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            let keys: [URLResourceKey] = [.fileSizeKey]
            if isDirectory.boolValue {

                //MARK: Directory Size
                if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, errorHandler: nil) {
                    for case let fileURL as URL in enumerator {
                        do {
                            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                                totalFileSize += Int64(size)
                            }
                        }
                    }
                }
            } else {
                //MARK: File Size
                do {
                    if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                        totalFileSize += Int64(size)
                    }
                }
            }
        }
    }

    return totalFileSize
}



public func totalSizeOnDisk(for path: URL) -> Int64 {
    return totalSizeOnDisk(for: [path])
}
