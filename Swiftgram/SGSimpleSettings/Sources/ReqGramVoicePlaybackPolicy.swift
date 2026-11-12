/// Applies only at natural completion, never to explicit queue navigation.
public enum ReqGramVoicePlaybackPolicy {
    public static func stopsAtEnd(enabled: Bool, isVoicePlayer: Bool, isVoiceMessage: Bool) -> Bool {
        return enabled && isVoicePlayer && isVoiceMessage
    }
}
