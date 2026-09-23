import MenubucketCore
import SwiftUI

/// Width, text and colour controls for a menu bar presentation, shared by a
/// widget's own settings and the app-wide defaults in App Settings.
///
/// `shown` is what the item will actually use, `inherited` what it would use
/// with nothing stored at this level. Setters store nil for a choice equal to
/// the inherited one, so picking the value the layer below already gives
/// leaves nothing pinned; picking "right" over a widget's "left" still stores
/// "right" instead of falling back to "left".
///
/// `inherited` is nil for the app-wide style: there every choice is stored,
/// because "Steady for all items" has to beat a widget that asks for Fit.
struct MenuBarStyleControls {
    var shown: MenuBarPresentation
    var inherited: MenuBarPresentation?
    /// nil where the controls are not for one item (the app-wide defaults).
    var usesOwnItem: Bool?
    var change: ((inout MenuBarPresentation) -> Void) -> Void

    /// `value`, or nil when it is what the layer below already gives.
    private func keep<T: Equatable>(_ value: T, _ below: (MenuBarPresentation) -> T) -> T? {
        guard let inherited else { return value }
        return value == below(inherited) ? nil : value
    }

    @ViewBuilder
    var width: some View {
        let presentation = shown
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(
                get: { presentation.effectiveWidth },
                set: { mode in change { $0.width = keep(mode, \.effectiveWidth) } }
            )) {
                Text("Steady").tag(MenuBarWidthMode.auto)
                Text("Fixed").tag(MenuBarWidthMode.fixed)
                Text("Fit").tag(MenuBarWidthMode.fit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)

            switch presentation.effectiveWidth {
            case .auto:
                Stepper(value: Binding(
                    get: { presentation.effectiveDigits },
                    set: { digits in
                        change { $0.digits = keep(digits, \.effectiveDigits) }
                    }
                ), in: 1...6) {
                    Text("Room for \(presentation.effectiveDigits) digit\(presentation.effectiveDigits == 1 ? "" : "s")")
                        .monospacedDigit()
                }
                .fixedSize()
                Self.hint("Keeps the item the same width as a reading goes from 9 to 10. A longer reading widens it once and it stays that wide.")
            case .fixed:
                // A stepper rather than a text field: a field that clamps on
                // every keystroke cannot be typed into ("1" became 32).
                Stepper(value: Binding(
                    get: { presentation.effectiveFixedWidth },
                    set: { width in
                        change { $0.valueWidth = keep(width, \.effectiveFixedWidth) }
                    }
                ), in: 32...120, step: 2) {
                    Text("\(Int(presentation.effectiveFixedWidth)) pt").monospacedDigit()
                }
                .fixedSize()
                switch usesOwnItem {
                case true?:
                    Self.hint("The text column is always this wide. Content that does not fit still widens it rather than being cut off.")
                case false?:
                    Self.hint("Fixed needs the item's own place in the menu bar; sharing the BarShelf icon, it keeps a steady width instead.")
                case nil:
                    Self.hint("The text column is always this wide. Items that share the BarShelf icon keep a steady width instead.")
                }
            case .fit:
                Self.hint("Exactly as wide as the current reading, so the item and its neighbours move when the digits change.")
            }
        }
    }

    @ViewBuilder
    var text: some View {
        let presentation = shown
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Picker("", selection: Binding(
                    get: { presentation.effectiveAlignment },
                    set: { value in change { $0.alignment = keep(value, \.effectiveAlignment) } }
                )) {
                    Image(systemName: "text.alignleft").tag(MenuBarAlignment.leading)
                        .help("Align left")
                    Image(systemName: "text.aligncenter").tag(MenuBarAlignment.center)
                        .help("Center")
                    Image(systemName: "text.alignright").tag(MenuBarAlignment.trailing)
                        .help("Align right")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)

                Picker("", selection: Binding(
                    get: { presentation.size ?? .regular },
                    set: { value in change { $0.size = keep(value) { $0.size ?? .regular } } }
                )) {
                    Text("S").tag(MenuBarTextSize.small).help("Small")
                    Text("M").tag(MenuBarTextSize.regular).help("Regular")
                    Text("L").tag(MenuBarTextSize.large).help("Large")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 90)

                Picker("", selection: Binding(
                    get: { presentation.weight?.rawValue ?? "default" },
                    // "Default weight" always means "not set here".
                    set: { value in
                        let weight = MenuBarWeight(rawValue: value)
                        change { $0.weight = weight.flatMap { keep(Optional($0)) { $0.weight } } ?? nil }
                    }
                )) {
                    Text("Default weight").tag("default")
                    Divider()
                    Text("Regular").tag(MenuBarWeight.regular.rawValue)
                    Text("Medium").tag(MenuBarWeight.medium.rawValue)
                    Text("Semibold").tag(MenuBarWeight.semibold.rawValue)
                    Text("Bold").tag(MenuBarWeight.bold.rawValue)
                }
                .labelsHidden()
                .frame(width: 130)
            }
            Toggle("Right-align numbers", isOn: Binding(
                get: { presentation.effectiveNumberAlignment == .right },
                set: { on in
                    let value: MenuBarNumberAlignment = on ? .right : .left
                    change { $0.numberAlignment = keep(value, \.effectiveNumberAlignment) }
                }
            ))
            Self.hint(presentation.effectiveNumberAlignment == .right
                ? "Alignment places the label and value rows. Right-aligned numbers keep the last digit and the unit still as 9 becomes 10."
                : "Alignment places the label and value rows. Left-aligned numbers start where the label does; the unit moves as 9 becomes 10.")
        }
    }

    @ViewBuilder
    var color: some View {
        let presentation = shown
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: Binding(
                get: { presentation.color ?? "automatic" },
                // "automatic" is stored when it differs from what is
                // inherited, so an item can take its warning colours back
                // from an app-wide monochrome.
                set: { value in change { $0.color = keep(value) { $0.color ?? "automatic" } } }
            )) {
                Text("Automatic").tag("automatic")
                Text("Monochrome").tag("monochrome")
                Divider()
                Text("Accent").tag("accent")
                Text("Good").tag("good")
                Text("Warning").tag("warning")
                Text("Danger").tag("danger")
                Text("Secondary").tag("secondary")
            }
            .labelsHidden()
            .frame(width: 150)
            Self.hint("Automatic keeps the widget's own warning colors; monochrome follows the menu bar.")
        }
    }

    static func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
