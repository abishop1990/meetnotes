import Foundation

let cliArgs = Array(CommandLine.arguments.dropFirst())
if let first = cliArgs.first, first.hasPrefix("--") {
    exit(CLI.run(cliArgs))
}
MeetNotesApp.main()
