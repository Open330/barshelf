import Foundation
import JavaScriptCore

struct AutomationFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Compilation only collects registrations. Native effects are allowed solely
/// inside a registered callback, after the host has enabled the extension.
final class AutomationScript {
    struct Binding {
        let combination: HotkeyGrammar.Combination
        let callback: JSValue
    }
    struct Remap: Equatable {
        let keyboardTypes: Set<Int64>
        let keys: [Int64: Int64]
    }

    private let context: JSContext
    private(set) var bindings: [Binding] = []
    private(set) var remap: Remap?
    private var invoking = false
    var command: ((String, JSValue) throws -> Void)?
    var report: ((String) -> Void)?

    init(source: String) throws {
        guard let context = JSContext() else { throw AutomationFailure("Cannot create JavaScript runtime.") }
        self.context = context
        let dispatch: @convention(block) (String, JSValue) -> Void = { [weak self] name, argument in
            guard let self else { return }
            guard self.invoking else {
                JSContext.current()?.exception = JSValue(newErrorFromMessage:
                    "Window actions must run inside a shortcut callback.", in: JSContext.current())
                return
            }
            do { try self.command?(name, argument) }
            catch {
                JSContext.current()?.exception = JSValue(newErrorFromMessage:
                    error.localizedDescription, in: JSContext.current())
            }
        }
        context.setObject(dispatch, forKeyedSubscript: "__command" as NSString)
        context.evaluateScript(Self.bootstrap)
        context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: "automation.js"))
        try checkException()
        guard let values = context.objectForKeyedSubscript("__bindings") else {
            throw AutomationFailure("Missing shortcut registrations.")
        }
        var used = Set<String>()
        let count = Int(values.forProperty("length").toInt32())
        guard (0...64).contains(count) else { throw AutomationFailure("At most 64 shortcuts are supported.") }
        for i in 0..<count {
            let item = values.atIndex(i)!
            guard let modifiers = item.forProperty("modifiers").toArray() as? [String],
                  let key = item.forProperty("key").toString() else {
                throw AutomationFailure("Shortcut modifiers and key must be strings.")
            }
            let combo = try HotkeyGrammar.parse((modifiers + [key]).joined(separator: "+")).get()
            guard used.insert("\(combo.keyCode):\(combo.modifiers)").inserted else {
                throw AutomationFailure("Duplicate shortcut: \(combo.canonicalText).")
            }
            bindings.append(Binding(combination: combo, callback: item.forProperty("run")))
        }
        if let value = context.objectForKeyedSubscript("__remap"), !value.isNull {
            guard let types = value.forProperty("keyboardTypes").toArray() as? [NSNumber],
                  !types.isEmpty, types.allSatisfy({ $0.doubleValue >= 0 && $0.doubleValue <= 65535 && $0.doubleValue.rounded() == $0.doubleValue }),
                  let map = value.forProperty("keys").toDictionary() as? [String: String], !map.isEmpty else {
                throw AutomationFailure("Fn remapping needs keyboardTypes (integer array) and keys (object).")
            }
            var keys: [Int64: Int64] = [:]
            for (key, arrow) in map {
                guard let code = Self.physicalKeys[key.lowercased()], let target = Self.arrows[arrow] else {
                    throw AutomationFailure("Unsupported Fn mapping: \(key) → \(arrow). Use letter keys and up/down/left/right.")
                }
                if let previous = keys[code], previous != target {
                    throw AutomationFailure("Conflicting mappings for physical key \(key).")
                }
                keys[code] = target
            }
            remap = Remap(keyboardTypes: Set(types.map(\.int64Value)), keys: keys)
        }
        guard !bindings.isEmpty || remap != nil else {
            throw AutomationFailure("The script did not register any shortcuts or Fn mappings.")
        }
    }

    func invoke(_ index: Int) {
        guard bindings.indices.contains(index) else { return }
        context.exception = nil
        invoking = true
        defer { invoking = false }
        bindings[index].callback.call(withArguments: [])
        do { try checkException() } catch { report?(error.localizedDescription) }
    }

    private func checkException() throws {
        if let error = context.exception {
            let message = error.toString() ?? "JavaScript error"
            let line = error.forProperty("line")?.toInt32() ?? 0
            context.exception = nil
            throw AutomationFailure(line > 0 ? "\(message) (line \(line))" : message)
        }
    }

    static let physicalKeys: [String: Int64] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
        "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, "ㅑ": 34, "ㅓ": 38, "ㅏ": 40, "ㅣ": 37,
    ]
    static let arrows: [String: Int64] = ["up": 126, "down": 125, "left": 123, "right": 124]

    private static let bootstrap = #"""
    "use strict";
    var __bindings = [];
    var __remap = null;
    const barshelf = Object.freeze({
      bind(modifiers, key, run) {
        if (!Array.isArray(modifiers) || !modifiers.every(x => typeof x === 'string') ||
            typeof key !== 'string' || typeof run !== 'function')
          throw new Error('bind expects modifiers, key, and a function');
        if (__bindings.length >= 64) throw new Error('At most 64 shortcuts are supported');
        __bindings.push({modifiers, key, run});
      },
      remapFn(options) {
        if (__remap) throw new Error('Declare Fn mappings once');
        if (!options || !Array.isArray(options.keyboardTypes) ||
            !options.keyboardTypes.every(x => Number.isInteger(x)) ||
            !options.keys || typeof options.keys !== 'object' || Array.isArray(options.keys))
          throw new Error('remapFn expects keyboardTypes (integer array) and keys (object)');
        __remap = options;
      },
      moveMouseToScreen(index) { __command('mouse', index); },
      moveWindowToScreen(index) { __command('window', index); },
      rotateWindowFocus(direction) { __command('rotate', direction); },
      log(message) { __command('log', String(message)); }
    });
    // Familiar aliases when moving Hammerspoon callbacks to JavaScript.
    const hs = Object.freeze({ hotkey: Object.freeze({bind: barshelf.bind}) });
    const moveMouseToScreen = barshelf.moveMouseToScreen;
    const moveWindowToScreen = barshelf.moveWindowToScreen;
    const rotateWindowFocus = barshelf.rotateWindowFocus;
    """#

    static let example = #"""
    // Monitor numbers are 1-based; see the display list in Settings.
    barshelf.remapFn({
      keyboardTypes: [91],
      keys: {i: "up", j: "left", k: "down", l: "right"}
    });
    hs.hotkey.bind(["alt", "shift"], "i", () => moveMouseToScreen(2));
    hs.hotkey.bind(["alt", "shift"], "u", () => moveMouseToScreen(1));
    hs.hotkey.bind(["ctrl", "alt", "shift"], "i", () => moveWindowToScreen(2));
    hs.hotkey.bind(["ctrl", "alt", "shift"], "u", () => moveWindowToScreen(1));
    hs.hotkey.bind(["alt", "shift"], "j", () => rotateWindowFocus("backward"));
    hs.hotkey.bind(["alt", "shift"], "k", () => rotateWindowFocus("forward"));
    """#
}
