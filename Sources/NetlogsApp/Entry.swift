import Foundation

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runBlocking() // never returns
        }
        if CommandLine.arguments.contains("--uicheck") {
            UICheck.runBlocking() // never returns
        }
        if let index = CommandLine.arguments.firstIndex(of: "--rangecheck") {
            let days = CommandLine.arguments.count > index + 1
                ? Int(CommandLine.arguments[index + 1]) ?? 7 : 7
            RangeCheck.runBlocking(days: days)
        }
        if CommandLine.arguments.contains("--diag") {
            DiagCheck.runBlocking() // never returns
        }
        if CommandLine.arguments.contains("--speed") {
            SpeedCheck.runBlocking() // never returns
        }
        if let index = CommandLine.arguments.firstIndex(of: "--wancheck") {
            let rest = CommandLine.arguments.dropFirst(index + 1).filter { !$0.hasPrefix("-") }
            WANCheck.runBlocking(host: rest.first, pinned: rest.dropFirst().first)
        }
        NetlogsScene.main()
    }
}
