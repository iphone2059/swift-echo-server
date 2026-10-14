import CESServerCore
import Foundation
import WinSDK

// Top-level entry: main.swift holds the entry point so the file corresponds to main.cpp, main.rs
// and main.zig in the sibling implementations.
struct SwiftEchoServer {
  static func writeUsage(_ handle: FileHandle) {
    handle.write(Data(cesUsageText.utf8))
  }

  static func help() { writeUsage(.standardOutput) }

  static func usageError() { writeUsage(.standardError) }
  static func run() -> CESExitCode {
    let args: [[UInt16]]
    do { args = try cesWindowsArguments() } catch {
      cesReport(stage: error.stage, error: error.code)
      return .network
    }
    let options: CESOptions
    do { options = try cesParseOptions(args) } catch {
      FileHandle.standardError.write(Data("Invalid arguments: \(error.message)\n".utf8))
      usageError()
      return .usage
    }
    if options.help {
      help()
      return .success
    }
    let control = cesProcessControl
    do {
      let registration = try CESConsoleRegistration(control: control)
      let result = cesRunServer(options: options, control: control)
      registration.keepAlive()
      return result
    } catch {
      FileHandle.standardError.write(
        Data("SetConsoleCtrlHandler failed: \(UInt32(bitPattern: error.code))\n".utf8))
      return .internalFailure
    }
  }
}
ExitProcess(UInt32(SwiftEchoServer.run().rawValue))
