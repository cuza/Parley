import Foundation

/// A card button's action as Google Chat encodes it: the app's function and whether the click opens the app's dialog.
/// The demo backend builds and reads its cards' actions with this, so the protobuf types stay inside Data.
public enum CardActionPayload {
    /// The encoded action that calls `function`, marked as opening the app's dialog when `opensDialog` is set.
    public static func data(function: String, opensDialog: Bool = false) -> Data {
        (try? Dynamite_CardAction.with { action in
            action.function = function
            if opensDialog { action.interaction = 1 }
        }.serializedData()) ?? Data()
    }
    /// The function an encoded action calls; nil when the data isn't an action.
    public static func function(of data: Data) -> String? {
        (try? Dynamite_CardAction(serializedBytes: data))?.function
    }
}
