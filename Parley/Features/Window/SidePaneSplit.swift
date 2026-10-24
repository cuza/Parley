import SwiftUI

/// A timeline (or list) with the thread or info pane to its right, as wide as the user dragged its divider: from
/// `paneWidth` to `paneMaxWidth`, and never so wide the timeline gets less than its minimum. The width is remembered.
struct SidePaneSplit<Main: View, Pane: View>: View {
    var open: Bool
    @ViewBuilder var main: Main
    @ViewBuilder var pane: Pane
    @AppStorage("sidePaneWidth") private var wanted: Double = ChatView.paneWidth
    @State private var room: CGFloat = 0  // this view's width, the timeline's and the pane's together
    @State private var dragStart: CGFloat?
    /// The pane's width: as wanted, within its bounds and what `room` leaves beside the timeline's minimum.
    static func shown(wanted: CGFloat, room: CGFloat) -> CGFloat {
        let most = min(ChatView.paneMaxWidth, max(ChatView.paneWidth, room - ChatView.timelineMinWidth - 1))
        return min(max(wanted, ChatView.paneWidth), most)
    }
    var body: some View {
        let width = Self.shown(wanted: wanted, room: room)
        HStack(spacing: 0) {
            main.frame(minWidth: ChatView.timelineMinWidth, maxWidth: .infinity)
            if open {
                Divider().overlay {
                    // A wider grip than the line, as a split view's divider has.
                    Color.clear.frame(width: 7).contentShape(Rectangle()).pointerStyle(.columnResize)
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { drag in
                                    let start = dragStart ?? width
                                    dragStart = start
                                    wanted = Self.shown(wanted: start - drag.translation.width, room: room)
                                }
                                .onEnded { _ in dragStart = nil })
                }.zIndex(1)
                pane.frame(width: width)
            }
        }
        // Past the room for the widest pane beside the narrowest timeline, more room changes nothing: no redraw per frame of a resize.
        .onGeometryChange(for: CGFloat.self) {
            min($0.size.width, ChatView.paneMaxWidth + ChatView.timelineMinWidth + 1)
        } action: {
            room = $0
        }
    }
}
