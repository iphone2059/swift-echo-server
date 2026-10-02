import CESServerCore
import Foundation
import WinSDK

@main struct SwiftEchoServer {
  static func help() {
    print(
      """
      Usage: swift-echo-server /p tcp|udp [/s port] [/t seconds] [/w seconds]
             [/b bytes] [/k udp-depth] [/threads workers] [/rio-buffer bytes]
             [/cq capacity] [/memory bytes] [/q] [/stats]
      Data I/O is always RIO; CQ notification is always IOCP. No fallback backend exists.
      """)
  }
  static func run() -> CESExitCode {
    let args: [[UInt16]]
    do { args = try cesWindowsArguments() } catch {
      cesReport(stage: error.stage, error: error.code)
      return .internalFailure
    }
    let options: CESOptions
    do { options = try cesParseOptions(args) } catch {
      FileHandle.standardError.write(Data("Invalid arguments: \(error.message)\n".utf8))
      help()
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
