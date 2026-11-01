import Foundation

/// Thin wrapper over the `swift package` / `swift build` command line.
public struct SwiftPM: Sendable {
    public init(packageDirectory: URL, scratchDirectory: URL, shell: Shell) {
        self.packageDirectory = packageDirectory
        self.scratchDirectory = scratchDirectory
        self.shell = shell
    }

    public struct BuildRequest: Sendable {
        public var platform: ApplePlatform
        /// SwiftPM rejects `--arch` together with `--triple`, so a build targets one
        /// architecture.
        public var architecture: String
        public var deploymentTarget: String?
        public var configuration: String
        public var verifyModuleInterfaces: Bool
        /// Builds resilient modules with `.swiftinterface` files. When false, only compiled
        /// `.swiftmodule` files are produced.
        public var libraryEvolution: Bool
        public var extraArguments: [String]
    }

    public let packageDirectory: URL
    public let scratchDirectory: URL
    public let shell: Shell

    /// Resolves dependencies and loads the manifest of the root package and every
    /// dependency.
    public func loadPackages() throws -> [ResolvedPackage] {
        let command = ["swift", "package"] + locationArguments + [
            "show-dependencies",
            "--format",
            "json",
        ]
        let seed = ScratchSeed(
            packageDirectory: packageDirectory,
            scratchDirectory: scratchDirectory,
            shell: shell
        )
        let json: String
        if seed.plant() {
            do {
                json = try shell.run(command, stream: false)
            } catch {
                // SwiftPM didn't accept the copied state; resolve from scratch instead.
                seed.remove()
                json = try shell.run(command, stream: false)
            }
        } else {
            json = try shell.run(command, stream: false)
        }
        let root = try JSONDecoder().decode(DependencyNode.self, from: Data(json.utf8))
        return try root.flattened().enumerated().map { index, node in
            // The root's path is used as given; dependencies live in checkouts.
            let directory = index == 0 ? packageDirectory : URL(fileURLWithPath: node.path)
            return try ResolvedPackage(
                identity: node.identity,
                directory: directory,
                manifest: dumpManifest(at: directory, identity: node.identity)
            )
        }
    }

    /// The directory where SwiftPM places built products for `request`.
    ///
    /// `--show-bin-path` gives the `Products` folder, but its last component is wrong for
    /// Mac Catalyst (`Release` instead of `Release-maccatalyst`), so the folder name is
    /// derived here.
    public func binPath(for request: BuildRequest) throws -> URL {
        let output = try shell.run(
            ["swift", "build"] + buildArguments(for: request) + ["--show-bin-path"],
            stream: false
        )
        guard let line = output.split(separator: "\n").last.map(String.init),
              line.hasPrefix("/")
        else {
            throw MakerError("Could not determine the build products directory from: \(output)")
        }
        return URL(fileURLWithPath: line).deletingLastPathComponent()
            .appendingPathComponent(request.configuration.capitalized + request.platform
                .productsFolderSuffix)
    }

    public func build(product: String, request: BuildRequest) throws {
        let arguments = try buildArguments(for: request)
        try shell.run(["swift", "build"] + arguments + ["--product", product])
    }

    /// The root package's resources as SwiftPM resolved them, keyed by target name, with
    /// absolute paths. Unlike the manifest's declarations, this already applies `exclude:`,
    /// implicit resource types and target boundaries.
    public func describeResources() throws -> [String: [PackageManifest.Resource]] {
        struct Description: Decodable {
            struct Target: Decodable {
                let name: String
                let resources: [PackageManifest.Resource]?
            }

            let targets: [Target]
        }
        let command = ["swift", "package"] + locationArguments + [
            "describe",
            "--type",
            "json",
        ]
        let output = try shell.run(command, stream: false)
        let json = output.firstIndex(of: "{").map { output[$0...] } ?? ""
        let description = try JSONDecoder().decode(Description.self, from: Data(json.utf8))
        return description.targets.reduce(into: [:]) { $0[$1.name] = $1.resources ?? [] }
    }

    public func computeChecksum(of archive: URL) throws -> String {
        let output = try shell.run(
            ["swift", "package", "compute-checksum", archive.path],
            in: archive.deletingLastPathComponent(),
            stream: false
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads a manifest with `swift package dump-package`, which doesn't resolve
    /// dependencies.
    func dumpManifest(at directory: URL, identity: String) throws -> PackageManifest {
        // A private scratch path keeps the dependency's checkout free of build state.
        let scratch = scratchDirectory.appendingPathComponent("manifests")
            .appendingPathComponent(identity)
        let location = ["--package-path", directory.path, "--scratch-path", scratch.path]
        let json = try shell.run(
            ["swift", "package"] + location + ["dump-package"],
            stream: false
        )
        return try JSONDecoder().decode(PackageManifest.self, from: Data(json.utf8))
    }

    func buildArguments(for request: BuildRequest) throws -> [String] {
        let sdkQuery = ["xcrun", "--sdk", request.platform.sdkName, "--show-sdk-path"]
        let sdkPath = try shell.run(sdkQuery, stream: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = locationArguments + [
            "--configuration", request.configuration,
            "--build-system", "swiftbuild",
            "--triple", request.platform.triple(
                architecture: request.architecture,
                deploymentTarget: request.deploymentTarget
            ),
            "--sdk", sdkPath,
        ]
        // Module interfaces only work for resilient modules. Without library evolution,
        // clients load the compiled .swiftmodule, so no interfaces are emitted.
        if request.libraryEvolution {
            arguments += [
                "--enable-parseable-module-interfaces",
                "-Xswiftc", "-enable-library-evolution",
            ]
            if !request.verifyModuleInterfaces {
                arguments += ["-Xswiftc", "-no-verify-emitted-module-interface"]
            }
        }
        return arguments + request.extraArguments
    }

    private var locationArguments: [String] {
        ["--package-path", packageDirectory.path, "--scratch-path", scratchDirectory.path]
    }
}

public struct MakerError: Error, CustomStringConvertible {
    public init(_ description: String) {
        self.description = description
    }

    public let description: String
}
