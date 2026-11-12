import Foundation

// Presentation only: format the supplied count, without fetching fresher data.
func fullChannelViewCountString(_ count: Int, locale: Locale) -> String {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: count)) ?? String(count)
}
