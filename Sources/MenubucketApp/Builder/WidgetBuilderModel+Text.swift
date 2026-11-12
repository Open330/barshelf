import BarShelfBuilder
import Foundation

// Wording that uses the app's terminology stays with the app; the model in
// BarShelfBuilder has no views.
extension WidgetBuilderModel {
    var sizeDescription: String {
        "\(LayoutSizeName.name(size)) — \(LayoutSizeName.description(size))"
    }
}
