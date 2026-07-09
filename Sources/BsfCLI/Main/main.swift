import Foundation
import BarShelfKit

// bsf is the short BarShelf CLI alias; behavior stays identical to `barshelf`.
exit(BarShelfMain.run(arguments: Array(CommandLine.arguments.dropFirst())))
