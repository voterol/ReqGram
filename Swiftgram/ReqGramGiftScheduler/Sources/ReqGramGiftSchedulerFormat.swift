import Foundation
import TelegramPresentationData
import TextFormat

/// Formats a scheduled delivery moment for display.
///
/// Uses the app's own date/time formatting so the plugin respects the user's
/// 12h/24h and date-separator preferences, rather than the original plugin's
/// hardcoded `%d.%m %H:%M`.
public func reqGramGiftSchedulerFormatWhen(timestamp: Int32, dateTimeFormat: PresentationDateTimeFormat) -> String {
    var t: time_t = time_t(timestamp)
    var timeinfo = tm()
    localtime_r(&t, &timeinfo)

    let day = Int(timeinfo.tm_mday)
    let month = Int(timeinfo.tm_mon) + 1
    let year = Int(timeinfo.tm_year) + 1900

    var nowTime: time_t = time_t(Date().timeIntervalSince1970)
    var nowInfo = tm()
    localtime_r(&nowTime, &nowInfo)
    let currentYear = Int(nowInfo.tm_year) + 1900

    let separator: String
    switch dateTimeFormat.dateFormat {
    case .monthFirst:
        separator = "/"
    case .dayFirst:
        separator = "."
    }

    let datePart: String
    switch dateTimeFormat.dateFormat {
    case .monthFirst:
        if year == currentYear {
            datePart = "\(month)\(separator)\(day)"
        } else {
            datePart = "\(month)\(separator)\(day)\(separator)\(year)"
        }
    case .dayFirst:
        if year == currentYear {
            datePart = "\(day)\(separator)\(month)"
        } else {
            datePart = "\(day)\(separator)\(month)\(separator)\(year)"
        }
    }

    let timePart = stringForShortTimestamp(
        hours: Int32(timeinfo.tm_hour),
        minutes: Int32(timeinfo.tm_min),
        dateTimeFormat: dateTimeFormat
    )
    return datePart + " " + timePart
}
