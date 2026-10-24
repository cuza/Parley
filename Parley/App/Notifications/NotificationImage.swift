import AppKit
import Intents
import ParleyDomain
import Security
import UserNotifications
import os

private let log = Logger(subsystem: "dev.cuza.Parley", category: "notifications")

/// Who sent it, on the banner: a communication notification (an INSendMessageIntent restyles the banner with the sender's
/// photo and name, and lets Focus match the sender), which needs the Communication Notifications entitlement. Reactions go the
/// same way, since they come from a person too. If the system refuses, the banner stays plain: no attached picture, whose
/// large preview broke the banner's Reply field.
@MainActor enum NotificationImage {
    static let px = 128
    static let entitlement = "com.apple.developer.usernotifications.communication"
    static let hasEntitlement: Bool =
        SecTaskCreateFromSelf(nil)
        .flatMap { SecTaskCopyValueForEntitlement($0, entitlement as CFString, nil) as? Bool } ?? false

    /// The banner with sender imagery: `communicate` makes it a communication notification; if that throws, `base` as is.
    static func content(
        for note: ChatNotification, base: UNMutableNotificationContent,
        load: @escaping @Sendable @MainActor (URL) async -> NSImage? = { await RemoteImage.image($0, px: px) },
        communicate: @MainActor (INSendMessageIntent, UNNotificationContent) async throws -> UNNotificationContent =
            donateAndUpdate
    ) async -> UNNotificationContent {
        let picture = await png(for: note.picture, load: load)
        do {
            return try await communicate(intent(for: note, image: picture), base)
        } catch {
            log.error(
                "communication notification refused: \(Redaction.redact(error.localizedDescription), privacy: .public)")
            return base
        }
    }

    /// Donates the incoming message (best effort), then lets the system restyle the banner. Throws without the entitlement.
    static func donateAndUpdate(_ intent: INSendMessageIntent, _ content: UNNotificationContent) async throws
        -> UNNotificationContent
    {
        guard hasEntitlement else { throw CocoaError(.featureUnsupported) }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        do {
            try await interaction.donate()
        } catch {
            log.error("donating the message failed: \(Redaction.redact(error.localizedDescription), privacy: .public)")
        }
        return try content.updating(from: intent)
    }

    /// The sender, and for a group DM or space its name and a second recipient, which is what makes the system show a group.
    /// The sender's handle is their email when known: the system matches it against Contacts for Focus "Allowed People".
    /// macOS has no separate group image (`setImage(_:forParameterNamed:)` is unavailable), so a space shows the sender's photo.
    /// The text stays in the banner's body, not the intent's `content`.
    static func intent(for note: ChatNotification, image: Data) -> INSendMessageIntent {
        let photo = INImage(imageData: image)
        let handle =
            note.sender.email.map { INPersonHandle(value: $0, type: .emailAddress) }
            ?? INPersonHandle(value: note.sender.id.rawValue, type: .unknown)
        let sender = INPerson(
            personHandle: handle, nameComponents: nil, displayName: note.sender.name, image: photo,
            contactIdentifier: nil, customIdentifier: note.sender.id.rawValue, isMe: false)
        let me = INPerson(
            personHandle: INPersonHandle(value: "me", type: .unknown), nameComponents: nil, displayName: nil,
            image: nil, contactIdentifier: nil, customIdentifier: nil, isMe: true)
        let intent = INSendMessageIntent(
            recipients: note.group == nil ? nil : [me, sender], outgoingMessageType: .outgoingMessageText,
            content: nil, speakableGroupName: note.group.map { INSpeakableString(spokenPhrase: $0) },
            conversationIdentifier: note.conversationID.rawValue, serviceName: nil, sender: sender, attachments: nil)
        return intent
    }

    /// The picture as PNG: the photo if it loads within `timeout`, else initials as `Avatar` draws them.
    static func png(
        for picture: ChatNotification.Picture, timeout: Duration = .seconds(1.5),
        load: @escaping @Sendable @MainActor (URL) async -> NSImage? = { await RemoteImage.image($0, px: px) }
    ) async -> Data {
        if let url = picture.url {
            // The loader stops on cancellation (URLSession does), so the timer bounds the wait.
            let loading = Task { await load(url) }
            let timer = Task {
                try await Task.sleep(for: timeout)
                loading.cancel()
            }
            let image = await loading.value
            timer.cancel()
            if let image { return draw { image.draw(in: $0) } }
        }
        return render(picture)
    }

    static func render(_ picture: ChatNotification.Picture) -> Data {
        draw { rect in
            NSColor(hue: Avatar.hue(picture.name), saturation: 0.35, brightness: 0.65, alpha: 1).setFill()
            rect.fill()
            let text = NSAttributedString(
                string: Avatar.initials(picture.name),
                attributes: [
                    .font: NSFont.systemFont(ofSize: rect.width * 0.4, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }

    /// A `px`-square PNG clipped to a circle, like `Avatar` draws a person.
    private static func draw(_ body: (NSRect) -> Void) -> Data {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return Data() }
        let rect = NSRect(x: 0, y: 0, width: px, height: px)
        let radius = rect.width / 2
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        body(rect)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }
}
