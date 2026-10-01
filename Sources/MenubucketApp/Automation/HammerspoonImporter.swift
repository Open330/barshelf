import Foundation

/// A deliberately narrow, lossless importer for the supported navigation
/// profile. Validate the *entire* token stream, including helper bodies, before
/// translating configurable tables and bindings. Never regex-extract a few
/// shortcuts from arbitrary Lua and silently discard the rest of the program.
enum HammerspoonImporter {
    struct Result {
        let script: String
        let summary: String
    }

    static func convert(_ source: String) throws -> Result {
        let profile = try extract(source)
        let reference = try extract(referenceSource)
        guard profile.skeleton == reference.skeleton else {
            throw AutomationFailure(String(localized: "This Lua file contains helper logic or APIs outside the supported navigation profile. Nothing was imported. Use a JavaScript extension for custom logic; see docs/AUTOMATION.md."))
        }
        let types = try json(profile.types)
        let keys = try json(profile.keys)
        let script = """
        // Imported from Hammerspoon. Original Lua file is unchanged.
        // Fn mappings use physical keys, including when Korean input is active.
        barshelf.remapFn({keyboardTypes: \(types), keys: \(keys)});
        \(profile.bindings.joined(separator: "\n"))
        """
        _ = try AutomationScript(source: script)
        return Result(script: script,
            summary: String(localized: "Imported \(profile.bindings.count) shortcuts and Fn mappings for keyboard types \(types). Window focus uses top-to-bottom, then left-to-right order. The native host restores input monitoring after sleep."))
    }

    private struct Profile {
        var skeleton: [String] = []
        var types: [Int] = []
        var keys: [String: String] = [:]
        var bindings: [String] = []
    }

    private struct Cursor {
        let tokens: [String]
        var index = 0
        var next: String? { index < tokens.count ? tokens[index] : nil }
        mutating func take() throws -> String {
            guard let next else { throw AutomationFailure(String(localized: "Incomplete Lua navigation profile.")) }
            index += 1
            return next
        }
        mutating func expect(_ token: String) throws {
            guard try take() == token else {
                throw AutomationFailure(String(localized: "Unsupported Lua syntax near token \(index); expected \(token). Nothing was imported."))
            }
        }
        mutating func string() throws -> String {
            let token = try take()
            guard token.hasPrefix("\""), let data = token.data(using: .utf8),
                  let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else {
                throw AutomationFailure(String(localized: "Expected a literal Lua string near token \(index)."))
            }
            return value
        }
        mutating func integer() throws -> Int {
            guard let value = Int(try take()), value >= 0, value <= 65535 else {
                throw AutomationFailure(String(localized: "Expected an integer from 0 to 65535 in the Lua profile."))
            }
            return value
        }
    }

    private static func extract(_ source: String) throws -> Profile {
        var cursor = Cursor(tokens: try tokenize(source))
        var profile = Profile()
        while cursor.next != nil {
            let remaining = cursor.tokens[cursor.index...]
            if remaining.starts(with: ["local", "INTERNAL_TYPES", "=", "{"]) {
                guard profile.types.isEmpty else { throw AutomationFailure(String(localized: "Duplicate INTERNAL_TYPES table.")) }
                cursor.index += 4
                while cursor.next != "}" {
                    profile.types.append(try cursor.integer())
                    if cursor.next != "}" { try cursor.expect(",") }
                }
                try cursor.expect("}")
                profile.skeleton.append("<keyboard-types>")
            } else if remaining.starts(with: ["local", "MAP", "=", "{"]) {
                guard profile.keys.isEmpty else { throw AutomationFailure(String(localized: "Duplicate MAP table.")) }
                cursor.index += 4
                while cursor.next != "}" {
                    let key: String
                    if cursor.next == "[" {
                        cursor.index += 1
                        key = try cursor.string()
                        try cursor.expect("]")
                    } else { key = try cursor.take() }
                    try cursor.expect("=")
                    let arrow = try cursor.string()
                    guard profile.keys[key] == nil else { throw AutomationFailure(String(localized: "Duplicate Fn mapping: \(key).")) }
                    profile.keys[key] = arrow
                    if cursor.next != "}" { try cursor.expect(",") }
                }
                try cursor.expect("}")
                profile.skeleton.append("<fn-map>")
            } else if remaining.starts(with: ["safeBind", "("]),
                      cursor.index == 0 || cursor.tokens[cursor.index - 1] != "function" {
                cursor.index += 2
                try cursor.expect("{")
                var mods: [String] = []
                while cursor.next != "}" {
                    mods.append(try cursor.string())
                    if cursor.next != "}" { try cursor.expect(",") }
                }
                try cursor.expect("}")
                try cursor.expect(",")
                let key = try cursor.string()
                try cursor.expect(",")
                _ = try cursor.string() // diagnostic label; no behavior
                for token in [",", "function", "(", ")"] { try cursor.expect(token) }
                let action = try cursor.take()
                try cursor.expect("(")
                let argument: String
                switch action {
                case "moveMouseToScreen", "moveWindowToScreen":
                    let screen = try cursor.integer()
                    guard screen > 0 else { throw AutomationFailure(String(localized: "Screen numbers start at 1.")) }
                    argument = String(screen)
                case "rotateWindowFocus":
                    let direction = try cursor.string()
                    guard ["forward", "backward"].contains(direction) else {
                        throw AutomationFailure(String(localized: "Unknown window rotation direction: \(direction)."))
                    }
                    argument = try json(direction)
                default: throw AutomationFailure(String(localized: "Unsupported Lua callback: \(action). Nothing was imported."))
                }
                for token in [")", "end", ")"] { try cursor.expect(token) }
                profile.bindings.append("hs.hotkey.bind(\(try json(mods)), \(try json(key)), () => \(action)(\(argument)));")
            } else {
                profile.skeleton.append(try cursor.take())
            }
        }
        return profile
    }

    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private static func tokenize(_ source: String) throws -> [String] {
        let pattern = #"\s+|--\[\[[\s\S]*?\]\]|--[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[A-Za-z_][A-Za-z_0-9]*|[0-9]+|==|~=|<=|>=|\.\.|[^\s]"#
        let regex = try NSRegularExpression(pattern: pattern)
        return try regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            let value = String(source[Range(match.range, in: source)!])
            if value.hasPrefix("--") || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            if value.hasPrefix("'") {
                // Quoting style may differ; complex Lua escapes require manual migration.
                let content = String(value.dropFirst().dropLast())
                guard !content.contains("\\") else { throw AutomationFailure(String(localized: "Lua string escapes require manual migration.")) }
                return try json(content)
            }
            return value
        }
    }

    static let referenceSource = #"""
    local application = require "hs.application"
    
    hs.logger.defaultLogLevel = "info"
    local log = hs.logger.new("init", "info")
    log.i("init.lua loaded at " .. os.date())
    
    local function safeBind(mods, key, name, fn)
      return hs.hotkey.bind(mods, key, function()
        local ok, err = pcall(fn)
        if not ok then log.ef("hotkey [%s] error: %s", name, tostring(err)) end
      end)
    end
    
    local fnDown = false
    local INTERNAL_TYPES = { 91 }
    
    local function flagsToList(flags)
      local list = {}
      for mod, on in pairs(flags) do
        if on and mod ~= "fn" then
          table.insert(list, mod)
        end
      end
      return list
    end
    
    local function isInternal(event)
      local kt = event:getProperty(hs.eventtap.event.properties.keyboardEventKeyboardType)
      for _, v in ipairs(INTERNAL_TYPES) do
        if kt == v then return true end
      end
    end
    
    local fnFlagsTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
      fnDown = e:getFlags().fn or false
      return false
    end)
    fnFlagsTap:start()
    
    local MAP = { 
      i = "up", j = "left", k = "down", l = "right",
      ["ㅑ"] = "up", ["ㅓ"] = "left", ["ㅏ"] = "down", ["ㅣ"] = "right",
    }
    
    local fnRemapTap = hs.eventtap.new(
      { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp },
      function(e)
        if not fnDown then return false end
        if not isInternal(e) then return false end
    
        local char = (e:getCharacters(true) or ""):lower()
        local arrow = MAP[char]
        if not arrow then return false end
    
        local modsList = flagsToList(e:getFlags())
        local isDown   = (e:getType() == hs.eventtap.event.types.keyDown)
    
        hs.eventtap.event.newKeyEvent(modsList, arrow, isDown):post()
        return true
      end
    )
    fnRemapTap:start()
    
    local eventtapWatchdog = hs.timer.doEvery(30, function()
      if not fnFlagsTap:isEnabled() then
        log.w("fnFlagsTap disabled by system, restarting")
        fnFlagsTap:start()
      end
      if not fnRemapTap:isEnabled() then
        log.w("fnRemapTap disabled by system, restarting")
        fnRemapTap:start()
      end
    end)
    
    function moveMouseToScreen(screenIndex)
      local screens = hs.screen.allScreens()
      if #screens >= screenIndex then
        local targetScreen = screens[screenIndex]
        local pt = hs.geometry.rectMidPoint(targetScreen:fullFrame())
        hs.mouse.absolutePosition(pt)
    
        local orderedWindows = hs.window.orderedWindows()
        for _, window in ipairs(orderedWindows) do
          if window:screen():id() == targetScreen:id() and window:title() ~= "" then
            window:focus()
            break
          end
        end
      end
    end
    
    function moveWindowToScreen(screenIndex)
      local screens = hs.screen.allScreens()
      if #screens >= screenIndex then
        local targetScreen = screens[screenIndex]
        local window = hs.window.focusedWindow()
        window:moveToScreen(targetScreen, false, true)
      end
    end
    
    local function focusAndCenterMouse(window)
      if not window then return end
      window:focus()
      hs.mouse.absolutePosition(hs.geometry.rectMidPoint(window:frame()))
    end
    
    function rotateWindowFocus(direction)
      local focusedWindow = hs.window.focusedWindow()
      if not focusedWindow then return end
      local focusedScreenId = focusedWindow:screen():id()
      local focusedId = focusedWindow:id()
    
      local items = {}
      for _, w in ipairs(hs.window.visibleWindows()) do
        local s = w:screen()
        if s and s:id() == focusedScreenId then
          local t = w:title()
          if t and t ~= "" then
            local f = w:frame()
            items[#items + 1] = { w = w, id = w:id(), x = f.x, y = f.y }
          end
        end
      end
      if #items <= 1 then return end
    
      table.sort(items, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        if a.x ~= b.x then return a.x < b.x end
        return a.id < b.id
      end)
    
      local idx
      for i, it in ipairs(items) do
        if it.id == focusedId then idx = i; break end
      end
    
      local nextIdx
      if idx == nil then
        nextIdx = direction == "forward" and 1 or #items
      elseif direction == "forward" then
        nextIdx = idx % #items + 1
      else
        nextIdx = (idx - 2) % #items + 1
      end
    
      focusAndCenterMouse(items[nextIdx].w)
    end
    
    safeBind({"alt", "shift"}, "i", "mouse->screen1", function() moveMouseToScreen(2) end)
    safeBind({"alt", "shift"}, "u", "mouse->screen2", function() moveMouseToScreen(1) end)
    
    safeBind({"ctrl", "alt", "shift"}, "i", "window->screen1", function() moveWindowToScreen(2) end)
    safeBind({"ctrl", "alt", "shift"}, "u", "window->screen2", function() moveWindowToScreen(1) end)
    
    safeBind({"alt", "shift"}, "j", "rotate-backward", function() rotateWindowFocus("backward") end)
    safeBind({"alt", "shift"}, "k", "rotate-forward",  function() rotateWindowFocus("forward")  end)
    
    log.i("hotkeys registered")
    """#
}
