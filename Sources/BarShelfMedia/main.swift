// barshelf-media <dir> [hero|popup|stills|film…]
//
// Records the landing page's videos and stills from the app's real views
// (see LandingMediaMode). A development tool: it is not part of
// BarShelf.app. It reaches into the app's internals the way a test does, so
// it only builds in debug; run it through scripts/render-landing-media.sh.
import Foundation

#if DEBUG
let arguments = CommandLine.arguments
let outputDirectory = arguments.count >= 2 ? arguments[1] : "./site/shots"
let only = Set(arguments.dropFirst(2))
exit(MainActor.assumeIsolated { LandingMediaMode.run(outputDir: outputDirectory, only: only) })
#else
FileHandle.standardError.write(Data("barshelf-media is a debug-only tool: build it with `swift build --product barshelf-media`.\n".utf8))
exit(2)
#endif
