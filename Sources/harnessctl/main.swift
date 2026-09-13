import Foundation

// Top-level entry point. `await` is used directly rather than dispatching onto a
// semaphore, because the install pipeline is an actor and blocking a thread here would
// stall its executor.
let code = await HarnessCtl.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(code)
