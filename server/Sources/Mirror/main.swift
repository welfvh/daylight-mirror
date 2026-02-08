// CLI wrapper for Daylight Mirror.
//
// Starts the mirror engine and runs until Ctrl+C.
// For the menu bar app, build and run the DaylightMirror target instead.

import Foundation
import MirrorEngine

setbuf(stdout, nil)

print("Daylight Mirror v6 -- CLI mode")
print("For the menu bar app, run: swift build -c release && .build/release/DaylightMirror")
print("---")

let engine = MirrorEngine()

signal(SIGINT) { _ in
    print("\nShutting down...")
    exit(0)
}

Task { @MainActor in
    await engine.start()
    print("---")
    print("Ctrl+C to stop (virtual display will disappear automatically)")
}

RunLoop.main.run()
