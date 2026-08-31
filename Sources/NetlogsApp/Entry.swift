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
        if CommandLine.arguments.contains("--diag") {
            DiagCheck.runBlocking() // never returns
        }
        if CommandLine.arguments.contains("--speed") {
            SpeedCheck.runBlocking() // never returns
        }
        NetlogsScene.main()
    }
}
