import Foundation

// A tool command that exits before reading its input must not kill the CLI.
signal(SIGPIPE, SIG_IGN)
await OAM.runMain()
