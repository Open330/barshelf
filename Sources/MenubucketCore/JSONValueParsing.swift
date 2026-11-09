import Foundation

/// JSON text to `JSONValue` without Codable.
///
/// `JSONValue.init(from:)` finds out what each value is by trying Bool, then
/// Double, then String, then an array, then an object, letting each wrong
/// guess throw. Over a few megabytes of command output — a script widget
/// asking `host.exec.run` to parse `muxa fleet status --json` every five
/// seconds — that was most of the app's CPU while the popup was open.
/// Foundation's parser reads the text once; this turns its result into a
/// `JSONValue` with the same meaning: `true`/`false` stay booleans, numbers
/// become `Double`, `null` stays `null`. Two differences no real payload
/// meets: a number below Double's range (`1e-400`) reads as 0 where
/// JSONDecoder throws, and an integer `-0` loses its sign.
extension JSONValue {
    public static func parse(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let value = JSONValue(foundation: object) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unsupported JSON value"))
        }
        return value
    }

    /// The value as `JSONSerialization` writes it.
    var foundationObject: Any {
        switch self {
        case let .string(string): return string
        case let .number(number): return NSNumber(value: number)
        case let .bool(bool): return NSNumber(value: bool)
        case .null: return NSNull()
        case let .array(values): return values.map(\.foundationObject)
        case let .object(values): return values.mapValues(\.foundationObject)
        }
    }

    /// A value from `JSONSerialization`; nil for anything it never produces.
    init?(foundation object: Any) {
        switch object {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            // JSON booleans arrive as the CFBoolean singletons; any other
            // number, 0 and 1 included, is a number.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if let decimal = number as? NSDecimalNumber {
                // Long decimals arrive as NSDecimalNumber, whose doubleValue
                // rounds differently from reading the text as a Double; and a
                // nonzero number too small for a Double is an error, as
                // JSONDecoder has it, not zero.
                guard let double = Double(decimal.stringValue), double.isFinite,
                      double != 0 || decimal.compare(NSDecimalNumber.zero) == .orderedSame
                else { return nil }
                self = .number(double)
            } else {
                self = .number(number.doubleValue)
            }
        case is NSNull:
            self = .null
        case let array as [Any]:
            var values: [JSONValue] = []
            values.reserveCapacity(array.count)
            for element in array {
                guard let value = JSONValue(foundation: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let dictionary as [String: Any]:
            var values: [String: JSONValue] = [:]
            values.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                guard let value = JSONValue(foundation: element) else { return nil }
                values[key] = value
            }
            self = .object(values)
        default:
            return nil
        }
    }
}

extension JSONValue {
    /// No NaN or infinity anywhere: JSON cannot carry them, and the Codable
    /// encoder's error for them is kept.
    var isFinite: Bool {
        switch self {
        case let .number(number): return number.isFinite
        case let .array(values): return values.allSatisfy(\.isFinite)
        case let .object(values): return values.values.allSatisfy(\.isFinite)
        default: return true
        }
    }
}

