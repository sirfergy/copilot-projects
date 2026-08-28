import Foundation
import CopilotProjectsCore
#if canImport(Darwin)
import Darwin
#endif

#if canImport(Darwin)
// Broken pipes are ordinary I/O errors for a GUI/CLI host, never a reason to
// terminate the entire process. Socket writes still return EPIPE to their caller;
// the bundled dtach helper installs its own signal disposition after exec.
signal(SIGPIPE, SIG_IGN)
#endif

// Single binary, two roles: a known subcommand runs the CLI client; no arguments
// launches the SwiftUI app. Unknown arguments are errors — silently launching a
// second GUI for a typo such as `--version` can create competing dtach clients.
let cliArgs = Array(CommandLine.arguments.dropFirst())
if let first = cliArgs.first, CLIMain.isCommand(first) {
    exit(CLIMain.run(cliArgs, checkAssets: {
        CopilotExtension.packagedAssetAvailable()
            && RemoteWebAssets.packagedAssetsAvailable()
    }))
}
if !cliArgs.isEmpty, !CLIMain.isCocoaLaunchArguments(cliArgs) {
    FileHandle.standardError.write(
        Data("copilot-projects: unknown command: \(cliArgs[0]) (try `copilot-projects help`)\n".utf8)
    )
    exit(2)
}

CopilotProjectsApp.main()
