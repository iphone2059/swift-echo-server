import CESServerCore
import Foundation
import WinSDK

@main struct SwiftEchoServer {
  static func writeUsage(_ handle: FileHandle) {
    handle.write(Data(cesUsageText.utf8))
  }

  static func help() { writeUsage(.standardOutput) }

  static func usageError() { writeUsage(.standardError) }
  static func run() -> CESExitCode {
    let args: [[UInt16]]
    do { args = try cesWindowsArguments() } catch {
      cesReport(stage: error.stage, error: error.code)
      return .internalFailure
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
    let control = CESSharedControl()
    do {
      let registration = try CESConsoleRegistration(control: control)
      let result = cesRunServer(options: options, control: control)
      registration.keepAlive()
      return result
    } catch {
      cesReport(stage: error.stage, error: error.code)
      return .internalFailure
    }
  }
  static func main() { ExitProcess(UInt32(run().rawValue)) }
}