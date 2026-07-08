import Foundation
import MbkKit

// mbk — BarShelf widget developer CLI. All logic lives in MbkKit so it can
// be unit-tested; this file only forwards the process arguments.
exit(MbkMain.run(arguments: Array(CommandLine.arguments.dropFirst())))
