import Foundation
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import SGSimpleSettings
//import PhoneNumberFormat

private func sgFilterZalgoIfNeeded(_ text: String) -> String {
    guard SGSimpleSettings.shared.ayuFilterZalgo, !text.isEmpty else {
        return text
    }
    let maxCombiningMarksInARow = 2
    var result = String.UnicodeScalarView()
    var run = 0
    for scalar in text.unicodeScalars {
        if CharacterSet.nonBaseCharacters.contains(scalar) {
            run += 1
            if run > maxCombiningMarksInARow {
                continue
            }
        } else {
            run = 0
        }
        result.append(scalar)
    }
    return String(result)
}

public extension EnginePeer {
    var compactDisplayTitle: String {
        return sgFilterZalgoIfNeeded(self.unfilteredCompactDisplayTitle)
    }

    func displayTitle(strings: PresentationStrings, displayOrder: PresentationPersonNameOrder) -> String {
        return sgFilterZalgoIfNeeded(self.unfilteredDisplayTitle(strings: strings, displayOrder: displayOrder))
    }
}

extension EnginePeer {
    private var unfilteredCompactDisplayTitle: String {
        switch self {
        case let .user(user):
            if let firstName = user.firstName, !firstName.isEmpty {
                return firstName
            } else if let lastName = user.lastName, !lastName.isEmpty {
                return lastName
            } else if let _ = user.phone {
                return "" //formatPhoneNumber("+\(phone)")
            } else {
                return "Deleted Account"
            }
        case let .legacyGroup(group):
            return group.title
        case let .channel(channel):
            return channel.title
        case let .community(community):
            return community.title
        case .secretChat:
            return ""
        }
    }

    private func unfilteredDisplayTitle(strings: PresentationStrings, displayOrder: PresentationPersonNameOrder) -> String {
        switch self {
        case let .user(user):
            if user.id.isReplies {
                return strings.DialogList_Replies
            }
            if let firstName = user.firstName, !firstName.isEmpty {
                if let lastName = user.lastName, !lastName.isEmpty {
                    switch displayOrder {
                    case .firstLast:
                        return "\(firstName) \(lastName)"
                    case .lastFirst:
                        return "\(lastName) \(firstName)"
                    }
                } else {
                    return firstName
                }
            } else if let lastName = user.lastName, !lastName.isEmpty {
                return lastName
            } else if let _ = user.phone {
                return "" //formatPhoneNumber("+\(phone)")
            } else {
                return strings.User_DeletedAccount
            }
        case let .legacyGroup(group):
            return group.title
        case let .channel(channel):
            return channel.title
        case let .community(community):
            return community.title
        case .secretChat:
            return ""
        }
    }
}

public extension EnginePeer.IndexName {
    func isLessThan(other: EnginePeer.IndexName, ordering: PresentationPersonNameOrder) -> ComparisonResult {
        switch self {
        case let .title(lhsTitle, _):
            let rhsString: String
            switch other {
            case let .title(title, _):
                rhsString = title
            case let .personName(first, last, _, _):
                switch ordering {
                case .firstLast:
                    if first.isEmpty {
                        rhsString = last
                    } else {
                        rhsString = first + last
                    }
                case .lastFirst:
                    if last.isEmpty {
                        rhsString = first
                    } else {
                        rhsString = last + first
                    }
                }
            }
            return lhsTitle.caseInsensitiveCompare(rhsString)
        case let .personName(lhsFirst, lhsLast, _, _):
            let lhsString: String
            switch ordering {
            case .firstLast:
                if lhsFirst.isEmpty {
                    lhsString = lhsLast
                } else {
                    lhsString = lhsFirst + lhsLast
                }
            case .lastFirst:
                if lhsLast.isEmpty {
                    lhsString = lhsFirst
                } else {
                    lhsString = lhsLast + lhsFirst
                }
            }
            let rhsString: String
            switch other {
            case let .title(title, _):
                rhsString = title
            case let .personName(first, last, _, _):
                switch ordering {
                case .firstLast:
                    if first.isEmpty {
                        rhsString = last
                    } else {
                        rhsString = first + last
                    }
                case .lastFirst:
                    if last.isEmpty {
                        rhsString = first
                    } else {
                        rhsString = last + first
                    }
                }
            }
            return lhsString.caseInsensitiveCompare(rhsString)
        }
    }
}
