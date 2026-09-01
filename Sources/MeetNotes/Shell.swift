import Foundation

struct ShellResult {
    let status: Int32
    let output: String
}

enum Shell {
    @discardableResult
    static func run(_ executable: String, _ args: [String]) throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ShellResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
