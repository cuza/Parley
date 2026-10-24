import SwiftUI

extension Binding where Value == Bool {
    /// Shown while `value` holds something: an alert or dialog about it closes by clearing it.
    init<Wrapped>(isPresent value: Binding<Wrapped?>) {
        self.init(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}
