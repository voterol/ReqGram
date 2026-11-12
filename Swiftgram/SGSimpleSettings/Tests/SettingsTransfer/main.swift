import Foundation

let s = SGSimpleSettings.shared
ReqGramSettingsTransfer.reset(settings: s)
precondition(try! JSONSerialization.jsonObject(with: ReqGramSettingsTransfer.exportData(settings: s)) is [String: Any])
var object = try! JSONSerialization.jsonObject(with: ReqGramSettingsTransfer.exportData(settings: s)) as! [String: Any]
var values = object["settings"] as! [String: Any]
values["reqGramDeletedOpacityPercent"] = 101
object["settings"] = values
ReqGramSettingsTransfer.importData(try! JSONSerialization.data(withJSONObject: object), settings: s)
precondition(s.reqGramDeletedOpacityPercent == 100)
values["unexpected"] = true
object["settings"] = values
do { try ReqGramSettingsTransfer.importData(try JSONSerialization.data(withJSONObject: object), settings: s); preconditionFailure("unknown key accepted") }
catch { }
print("ReqGram settings transfer tests passed")
