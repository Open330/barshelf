// Tailscale status for BarShelf, run as `osascript -l JavaScript tailscale.js`.
//
// Finds the Tailscale CLI (the Mac app's bundled binary or a standalone
// `tailscale`), runs `tailscale status --json` and prints a smaller document
// the workflow can lay out: `Peer` is a map keyed by node key, which the
// workflow DSL cannot iterate, so the peers become a sorted list here.
// Read-only: it never runs `up`, `down`, `set` or anything that changes state.
ObjC.import('Foundation')

const CANDIDATES = [
  '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
  '/opt/homebrew/bin/tailscale',
  '/usr/local/bin/tailscale',
  '/usr/bin/tailscale'
]

function findCLI() {
  const fm = $.NSFileManager.defaultManager
  for (const path of CANDIDATES) {
    if (fm.isExecutableFileAtPath(path)) return path
  }
  return null
}

function runCLI(path, args) {
  const task = $.NSTask.alloc.init
  task.executableURL = $.NSURL.fileURLWithPath(path)
  task.arguments = $(args)
  const out = $.NSPipe.pipe
  const err = $.NSPipe.pipe
  task.standardOutput = out
  task.standardError = err
  task.standardInput = $.NSFileHandle.fileHandleWithNullDevice
  // The Mac app's binary only acts as a CLI when TERM is set; without it,
  // as under BarShelf's minimal environment, it tries to start the GUI.
  const env = $.NSProcessInfo.processInfo.environment.mutableCopy
  if (env.objectForKey('TERM').isNil()) env.setObjectForKey('dumb', 'TERM')
  task.environment = env
  if (!task.launchAndReturnError(null)) return { code: -1, stdout: '', stderr: 'could not launch' }
  // Read stdout to the end before waiting, so a large tailnet cannot fill
  // the pipe and stall the CLI. BarShelf's exec timeout bounds the whole run.
  const data = out.fileHandleForReading.readDataToEndOfFile
  task.waitUntilExit
  const errData = err.fileHandleForReading.readDataToEndOfFile
  const text = (d) => $.NSString.alloc.initWithDataEncoding(d, $.NSUTF8StringEncoding).js || ''
  return { code: task.terminationStatus, stdout: text(data), stderr: text(errData) }
}

function shortName(node) {
  const dns = (node.DNSName || '').split('.')[0]
  return dns || node.HostName || '?'
}

function seenMs(iso) {
  if (!iso || iso.indexOf('0001-') === 0) return null
  const ms = Date.parse(iso)
  return isNaN(ms) ? null : ms
}

function run() {
  const cli = findCLI()
  if (!cli) return JSON.stringify({ installed: false, ok: false })
  const result = runCLI(cli, ['status', '--json'])
  let status = null
  try { status = JSON.parse(result.stdout) } catch (e) { status = null }
  if (!status || typeof status !== 'object') {
    const firstLine = (result.stderr || result.stdout || '').split('\n').find((l) => l.trim()) || ''
    return JSON.stringify({ installed: true, ok: false, error: firstLine.slice(0, 160) })
  }

  const peers = Object.values(status.Peer || {}).map((p) => ({
    id: String(p.ID || p.PublicKey || shortName(p)),
    name: shortName(p),
    ip: (p.TailscaleIPs || [])[0] || '',
    os: p.OS || '',
    online: p.Online === true,
    lastSeen: seenMs(p.LastSeen),
    exitNode: p.ExitNode === true,
    exitNodeOption: p.ExitNodeOption === true
  }))
  peers.sort((a, b) => (a.online === b.online ? a.name.localeCompare(b.name) : a.online ? -1 : 1))
  const exit = peers.find((p) => p.exitNode) || null
  const self = status.Self || {}
  const online = peers.filter((p) => p.online).length

  return JSON.stringify({
    installed: true,
    ok: true,
    backendState: status.BackendState || 'NoState',
    version: (status.Version || '').split('-')[0],
    self: {
      name: shortName(self),
      ip: (self.TailscaleIPs || status.TailscaleIPs || [])[0] || '',
      os: self.OS || '',
      online: self.Online === true
    },
    exitNode: exit ? exit.name : null,
    health: (status.Health || []).slice(0, 3),
    peers: peers,
    peerCount: peers.length,
    onlineCount: online,
    offlineCount: peers.length - online
  })
}
