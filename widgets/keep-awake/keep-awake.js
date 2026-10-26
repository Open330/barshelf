// Keep Awake helper for BarShelf, run as `osascript -l JavaScript keep-awake.js <command>`.
//
// PowerDisplayGuard (a LaunchAgent) owns the Mac's power policy and is the
// only thing that sets SleepDisabled. This helper never touches pmset. It
// reads the guard's status.json and writes or removes override.json, the
// one request the guard accepts:
//
//   status                 → normalized JSON for the widget
//   set <seconds> <lid>    → keep awake for that long (capped at 12 h)
//   until <HH:MM> <lid>    → keep awake until the next such time (capped)
//   cancel                 → remove the request
//
// There is no indefinite option on purpose: a forgotten session must not
// block battery sleep for days.
ObjC.import('Foundation')
ObjC.import('stdlib')

const MAX_SECONDS = 12 * 3600
const STALE_AFTER_SECONDS = 15

function guardDirectory() {
  // KEEP_AWAKE_GUARD_DIR exists for tests only; BarShelf never sets it.
  const override = $.NSProcessInfo.processInfo.environment.objectForKey('KEEP_AWAKE_GUARD_DIR')
  if (override && !override.isNil()) return override.js
  return $.NSHomeDirectory().js + '/Library/Application Support/PowerDisplayGuard'
}

function readJSON(path) {
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null)
  if (!text || text.isNil()) return null
  try { return JSON.parse(text.js) } catch (e) { return { __invalid: true } }
}

function iso(date) { return date.toISOString() }

function writeOverride(seconds, lid) {
  const dir = guardDirectory()
  const fm = $.NSFileManager.defaultManager
  if (!fm.fileExistsAtPath(dir)) throw new Error('PowerDisplayGuard is not installed')
  const clamped = Math.max(60, Math.min(MAX_SECONDS, Math.round(seconds)))
  const now = new Date()
  const body = {
    id: $.NSUUID.UUID.UUIDString.js,
    createdAt: iso(now),
    until: iso(new Date(now.getTime() + clamped * 1000)),
    lidClosed: lid === 'true' || lid === '1',
    source: 'barshelf'
  }
  // Atomic: Foundation writes a temporary file beside it and renames it
  // into place, so the guard never reads half a request. Then keep it
  // readable by this user only.
  const path = dir + '/override.json'
  if (!$(JSON.stringify(body)).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) {
    throw new Error('could not write ' + path)
  }
  fm.setAttributesOfItemAtPathError($({ NSFilePosixPermissions: 0o600 }), path, null)
  return { ok: true, until: body.until, cappedFrom: seconds > MAX_SECONDS ? Math.round(seconds) : null }
}

function secondsUntil(hhmm) {
  const match = /^([01]?\d|2[0-3]):([0-5]\d)$/.exec(String(hhmm).trim())
  if (!match) throw new Error('time must be HH:MM, got ' + hhmm)
  const now = new Date()
  const target = new Date(now)
  target.setHours(Number(match[1]), Number(match[2]), 0, 0)
  if (target <= now) target.setDate(target.getDate() + 1)
  return (target - now) / 1000
}

function cancel() {
  const path = guardDirectory() + '/override.json'
  const fm = $.NSFileManager.defaultManager
  if (fm.fileExistsAtPath(path) && !fm.removeItemAtPathError(path, null)) throw new Error('could not remove ' + path)
  return { ok: true }
}

function clock(seconds) {
  const s = Math.max(0, Math.round(seconds))
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60)
  if (h > 0) return h + ':' + String(m).padStart(2, '0')
  if (m > 0) return m + 'm'
  return s + 's'
}

function localTime(date) {
  return String(date.getHours()).padStart(2, '0') + ':' + String(date.getMinutes()).padStart(2, '0')
}

const KNOWN = { caffeinate: 'caffeinate', Amphetamine: 'Amphetamine' }

function status() {
  const dir = guardDirectory()
  const raw = readJSON(dir + '/status.json')
  const pending = readJSON(dir + '/override.json')
  const now = new Date()
  const out = {
    state: 'missing', phase: null, onAC: null, holding: false, sleepDisabled: false,
    ageSeconds: null, remaining: '', untilText: '', graceText: '',
    untilMs: 0, fromMs: 0,
    lidClosedEffective: false, note: '', requestPending: false,
    blockers: [], blockerCount: 0, icon: 'exclamationmark.triangle', menuLabel: '!'
  }
  if (!raw) return out
  if (raw.__invalid || raw.version !== 1) { out.state = 'invalid'; return out }
  const updated = new Date(raw.updatedAt)
  out.ageSeconds = isNaN(updated) ? null : Math.round((now - updated) / 1000)
  out.phase = raw.phase || null
  out.onAC = !!raw.onAC
  out.holding = !!raw.holding
  out.sleepDisabled = !!raw.sleepDisabled
  out.blockers = (raw.blockers || []).map(b => ({
    id: String(b.pid) + '-' + (b.type || ''),
    process: KNOWN[b.process] || b.process || 'pid ' + b.pid,
    type: b.type || '',
    name: b.assertionName || b.name || ''
  }))
  out.blockerCount = out.blockers.length
  const o = raw.override
  if (o && o.until) {
    const until = new Date(o.until)
    out.remaining = clock((until - now) / 1000)
    out.untilText = localTime(until)
    out.untilMs = until.getTime()
    const created = new Date(o.createdAt || raw.updatedAt)
    out.fromMs = isNaN(created) ? now.getTime() : created.getTime()
    out.lidClosedEffective = o.lidClosedEffective === undefined ? !!o.lidClosed : !!o.lidClosedEffective
    out.note = o.note || ''
  }
  if (raw.phase === 'grace' && typeof raw.graceRemaining === 'number') out.graceText = clock(raw.graceRemaining)
  // A request the guard has not picked up yet (it echoes the id back).
  out.requestPending = !!(pending && pending.id && !(o && o.id === pending.id))
  if (out.ageSeconds === null || out.ageSeconds > STALE_AFTER_SECONDS) {
    out.state = 'stale'; out.icon = 'exclamationmark.triangle'; out.menuLabel = '!'
    return out
  }
  out.state = 'ok'
  switch (raw.phase) {
    case 'override': out.icon = 'cup.and.saucer.fill'; out.menuLabel = out.remaining; break
    case 'grace': out.icon = 'timer'; out.menuLabel = out.graceText; break
    case 'ac': out.icon = 'bolt.fill'; out.menuLabel = ''; break
    default: out.icon = 'moon.zzz'; out.menuLabel = ''
  }
  return out
}

function run(argv) {
  try {
    switch (argv[0]) {
      case 'status': return JSON.stringify(status())
      case 'set': return JSON.stringify(writeOverride(Number(argv[1]), argv[2]))
      case 'until': return JSON.stringify(writeOverride(secondsUntil(argv[1]), argv[2]))
      case 'cancel': return JSON.stringify(cancel())
      default: throw new Error('usage: status | set <seconds> <lid> | until <HH:MM> <lid> | cancel')
    }
  } catch (e) {
    $.NSFileHandle.fileHandleWithStandardError.writeData($(String(e.message || e) + '\n').dataUsingEncoding($.NSUTF8StringEncoding))
    $.exit(1)
  }
}
