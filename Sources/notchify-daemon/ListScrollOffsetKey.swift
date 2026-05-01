import SwiftUI

/// Preference key carrying the hover list's scroll offset (in
/// points, top-of-content relative to the ScrollView's top). Read
/// via a GeometryReader inside the ScrollView's content.
struct ListScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
