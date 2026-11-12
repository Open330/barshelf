import MenubucketApp

// The app itself is the `MenubucketApp` library; see `BarShelfApp.main()`.
// Top-level code runs on the main thread.
MainActor.assumeIsolated { BarShelfApp.main() }
