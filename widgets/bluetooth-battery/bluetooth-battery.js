// Bluetooth battery helper for BarShelf, run as
// `osascript -l JavaScript bluetooth-battery.js`.
//
// Reads the battery levels macOS already knows about and prints one JSON
// object for the workflow. Nothing here talks to a device or changes a
// setting; it only runs two read-only tools, without a shell:
//
//   /usr/sbin/system_profiler SPBluetoothDataType -json
//       connected devices with their names and levels, including AirPods
//       left / right / case
//   /usr/sbin/ioreg -r -k BatteryPercent -a
//       HID devices (mice, keyboards, trackpads, some third-party ones) that
//       publish BatteryPercent; used for devices system_profiler lists
//       without a level
//
// Serial numbers and firmware versions are never copied into the output.
ObjC.import('Foundation')

function runTool(path, args) {
  try {
    const task = $.NSTask.alloc.init
    task.launchPath = path
    task.arguments = args
    const pipe = $.NSPipe.pipe
    task.standardOutput = pipe
    task.standardError = $.NSFileHandle.fileHandleWithNullDevice
    task.launch
    const data = pipe.fileHandleForReading.readDataToEndOfFile
    task.waitUntilExit
    return data
  } catch (e) {
    return null
  }
}

function pct(text) {
  if (text === undefined || text === null) return null
  const n = parseInt(String(text), 10)
  return isNaN(n) ? null : Math.max(0, Math.min(100, n))
}

function normAddress(a) {
  return String(a || '').toUpperCase().replace(/-/g, ':')
}

function iconFor(kind, name) {
  const k = (String(kind || '') + ' ' + String(name || '')).toLowerCase()
  if (k.indexOf('airpods') >= 0) return 'airpods'
  if (k.indexOf('headphone') >= 0 || k.indexOf('headset') >= 0 || k.indexOf('speaker') >= 0) return 'headphones'
  if (k.indexOf('trackpad') >= 0) return 'hand.point.up.left'
  if (k.indexOf('mouse') >= 0) return 'magicmouse'
  if (k.indexOf('keyboard') >= 0) return 'keyboard'
  if (k.indexOf('game') >= 0 || k.indexOf('controller') >= 0) return 'gamecontroller'
  return 'battery.75percent'
}

function fromSystemProfiler() {
  const data = runTool('/usr/sbin/system_profiler', ['SPBluetoothDataType', '-json'])
  if (!data) return []
  const text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding)
  if (!text || text.isNil()) return []
  let root
  try { root = JSON.parse(text.js) } catch (e) { return [] }
  const out = []
  for (const controller of (root.SPBluetoothDataType || [])) {
    for (const entry of (controller.device_connected || [])) {
      for (const name of Object.keys(entry)) {
        const d = entry[name] || {}
        out.push({
          address: normAddress(d.device_address),
          name: name,
          kind: d.device_minorType || '',
          main: pct(d.device_batteryLevelMain !== undefined ? d.device_batteryLevelMain : d.device_batteryLevel),
          left: pct(d.device_batteryLevelLeft),
          right: pct(d.device_batteryLevelRight),
          case: pct(d.device_batteryLevelCase),
        })
      }
    }
  }
  return out
}

function fromIoreg() {
  const data = runTool('/usr/sbin/ioreg', ['-r', '-k', 'BatteryPercent', '-a'])
  if (!data || data.length === 0) return []
  let list
  try {
    const plist = $.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(data, 0, null, null)
    list = ObjC.deepUnwrap(plist)
  } catch (e) { return [] }
  if (!Array.isArray(list)) return []
  const out = []
  for (const d of list) {
    if (!d || d.BatteryPercent === undefined) continue
    out.push({
      address: normAddress(d.DeviceAddress),
      name: typeof d.Product === 'string' ? d.Product.trim() : '',
      main: pct(d.BatteryPercent),
    })
  }
  return out
}

function run() {
  const devices = fromSystemProfiler()
  const hid = fromIoreg()
  // Fill a missing level from ioreg; add HID devices system_profiler missed.
  for (const h of hid) {
    const match = devices.find(d => h.address && d.address === h.address)
    if (match) {
      if (match.main === null && match.left === null && match.right === null) match.main = h.main
    } else if (h.name) {
      devices.push({ address: h.address, name: h.name, kind: '', main: h.main, left: null, right: null, case: null })
    }
  }

  const rows = []
  devices.forEach((d, i) => {
    const buds = [d.left, d.right].filter(v => v !== null)
    let level = d.main
    if (level === null && buds.length) level = Math.min.apply(null, buds)
    if (level === null) level = d.case
    if (level === null) return // no battery reading: not this widget's business
    const split = d.left !== null || d.right !== null || d.case !== null
    const parts = []
    const partsKo = []
    if (d.left !== null) { parts.push('L ' + d.left + '%'); partsKo.push('왼쪽 ' + d.left + '%') }
    if (d.right !== null) { parts.push('R ' + d.right + '%'); partsKo.push('오른쪽 ' + d.right + '%') }
    if (d.case !== null) { parts.push('Case ' + d.case + '%'); partsKo.push('케이스 ' + d.case + '%') }
    rows.push({
      id: 'bt-' + (d.address ? d.address.replace(/:/g, '') : String(i)),
      name: d.name || d.kind || 'Bluetooth device',
      kind: d.kind,
      icon: (d.left !== null || d.right !== null) ? 'airpods' : iconFor(d.kind, d.name),
      level: level,
      detail: split ? parts.join(' · ') : (d.kind || 'Bluetooth'),
      detailKo: split ? partsKo.join(' · ') : (d.kind || 'Bluetooth'),
    })
  })
  rows.sort((a, b) => a.level - b.level || a.name.localeCompare(b.name))
  const lowest = rows.length ? { name: rows[0].name, level: rows[0].level } : null
  return JSON.stringify({ count: rows.length, devices: rows, lowest: lowest })
}
