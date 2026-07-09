import Foundation
import BarShelfKit

// barshelf — BarShelf widget developer CLI. All logic lives in BarShelfKit so it can
// be unit-tested; this file only forwards the process arguments.
exit(BarShelfMain.run(arguments: Array(CommandLine.arguments.dropFirst())))
