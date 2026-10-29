import Foundation

public struct ShellError: Error, CustomStringConvertible {
  public let command: [String]
  public let status: Int32
  public let output: String

  public var description: String {
    let tail = output.split(separator: "\n", omittingEmptySubsequences: false).suffix(40)
      .joined(separator: "\n")
    return "Command failed (exit \(status)): \(command.joined(separator: " "))\n\(tail)"
  }
}

/// Runs external tools (`swift`, `xcrun`, `libtool`, `xcodebuild`, ...).
public struct Shell: Sendable {
  public init(streamOutput: Bool = false) {
    self.streamOutput = streamOutput
  }

  /// When true, child output is streamed to stderr instead of being captured.
  public var streamOutput: Bool

  /// Runs `arguments` (resolved through `PATH`) and returns its standard output.
  /// Standard error is folded into the error message on failure.
  @discardableResult
  public func run(
    _ arguments: [String],
    in directory: URL? = nil,
    stream: Bool? = nil
  ) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    if let directory {
      process.currentDirectoryURL = directory
    }

    let shouldStream = stream ?? streamOutput
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let collected = OutputCollector()
    let group = DispatchGroup()
    for (pipe, isError) in [(stdout, false), (stderr, true)] {
      group.enter()
      DispatchQueue.global().async {
        let handle = pipe.fileHandleForReading
        while true {
          let chunk = handle.availableData
          if chunk.isEmpty {
            break
          }
          collected.append(chunk, isError: isError)
          if shouldStream {
            FileHandle.standardError.write(chunk)
          }
        }
        group.leave()
      }
    }

    try process.run()
    process.waitUntilExit()
    group.wait()

    let (out, err) = collected.strings()
    guard process.terminationStatus == 0 else {
      throw ShellError(
        command: arguments,
        status: process.terminationStatus,
        output: out + err
      )
    }
    return out
  }
}

private final class OutputCollector: @unchecked Sendable {
  func append(_ data: Data, isError: Bool) {
    lock.lock(); defer { lock.unlock() }
    if isError {
      err.append(data)
    } else {
      out.append(data)
    }
  }

  func strings() -> (String, String) {
    lock.lock(); defer { lock.unlock() }
    return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
  }

  private let lock = NSLock()
  private var out = Data()
  private var err = Data()
}
