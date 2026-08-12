import Darwin
import Foundation

let exitCode = await CLIApplication.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(exitCode)
