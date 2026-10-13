import Foundation
import SGSimpleSettings

/// Shared text and peer helpers used across the AyuGram feature set.
public enum AyuUtils {
    // MARK: Zalgo

    /// Number of consecutive combining marks tolerated before the rest are
    /// dropped. One mark is legitimate in many scripts; long stacks are not.
    private static let maxCombiningMarksInARow = 2

    /// Strips excessive Unicode combining marks ("Zalgo") while leaving normal
    /// diacritics intact.
    ///
    /// This is intentionally conservative: it never removes base characters, so
    /// text in scripts that rely on combining marks stays readable.
    public static func filterZalgo(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = String.UnicodeScalarView()
        var run = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.nonBaseCharacters.contains(scalar) {
                run += 1
                if run > AyuUtils.maxCombiningMarksInARow {
                    continue
                }
            } else {
                run = 0
            }
            result.append(scalar)
        }
        return String(result)
    }

    /// Applies the Zalgo filter only when the setting is enabled.
    public static func filterZalgoIfNeeded(_ text: String) -> String {
        guard SGSimpleSettings.shared.ayuFilterZalgo else { return text }
        return AyuUtils.filterZalgo(text)
    }

    // MARK: Peer id formatting

    /// Formats a peer id per the `ayuShowPeerId` setting.
    ///
    /// - Parameters:
    ///   - bareId: the raw positive id.
    ///   - isChannelOrGroup: channels and supergroups are negated and prefixed
    ///     in Bot API form.
    ///   - isLegacyGroup: legacy (basic) groups are only negated.
    /// - Returns: `nil` when ids are configured to be hidden.
    public static func formatPeerId(bareId: Int64, isChannelOrGroup: Bool, isLegacyGroup: Bool) -> String? {
        switch SGSimpleSettings.shared.ayuPeerIdDisplayEnum {
        case .hidden:
            return nil
        case .telegram:
            return "\(bareId)"
        case .bot:
            if isChannelOrGroup {
                return "-100\(bareId)"
            }
            if isLegacyGroup {
                return "-\(bareId)"
            }
            return "\(bareId)"
        }
    }

    // MARK: Marks

    /// The replacement for the "edited" label, or `nil` to keep the app default.
    public static var editedMark: String? {
        let value = SGSimpleSettings.shared.ayuEditedMark.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The single deleted-message opacity policy used by every presentation.
    /// The setting intentionally has only the Android parity states: 70% or 100%.
    public static var deletedMessageAlpha: Double {
        return SGSimpleSettings.shared.ayuSemiTransparentDeleted ? 0.7 : 1.0
    }

    // MARK: Formatting

    /// Human readable byte size, used by the message details sheet.
    public static func formatFileSize(_ bytes: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
