import SwiftUI

extension BrandInfo {
    /// The accent colour for SwiftUI.
    var accentColor: Color {
        let (r, g, b) = accentRGB
        return Color(red: r, green: g, blue: b)
    }
}
