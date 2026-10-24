import AppKit

/// View ▸ Bigger and Smaller (⌘+ and ⌘−): how much larger or smaller than usual message text is drawn in the timeline
/// and the composer, in Mail's steps, saved as a setting.
enum TextSize {
    static let key = "messageTextScale"
    static let steps: [CGFloat] = [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]
    static var scale: CGFloat { (UserDefaults.standard.object(forKey: key) as? Double).map { CGFloat($0) } ?? 1 }
    /// Posted when the scale changes, so the timeline and composers lay their text out again.
    static let changed = Notification.Name("Parley.textSizeChanged")
    /// `by` steps from the step nearest `scale`, stopping at the ends.
    static func next(from scale: CGFloat, by step: Int) -> CGFloat {
        let nearest = steps.indices.min { abs(steps[$0] - scale) < abs(steps[$1] - scale) } ?? 1
        return steps[min(max(nearest + step, 0), steps.count - 1)]
    }
    @MainActor static func set(_ value: CGFloat) {
        guard value != scale else { return }
        UserDefaults.standard.set(Double(value), forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
