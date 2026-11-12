// Run with Sources/ReqGramVoicePlaybackPolicy.swift; no iOS dependencies.
for enabled in [false, true] {
    for isVoicePlayer in [false, true] {
        for isVoiceMessage in [false, true] {
            let actual = ReqGramVoicePlaybackPolicy.stopsAtEnd(
                enabled: enabled, isVoicePlayer: isVoicePlayer, isVoiceMessage: isVoiceMessage
            )
            precondition(actual == (enabled && isVoicePlayer && isVoiceMessage))
        }
    }
}
// Round videos share the voice player; audio files can share the audio implementation.
precondition(!ReqGramVoicePlaybackPolicy.stopsAtEnd(enabled: true, isVoicePlayer: true, isVoiceMessage: false))
precondition(!ReqGramVoicePlaybackPolicy.stopsAtEnd(enabled: true, isVoicePlayer: false, isVoiceMessage: true))
print("Voice playback decision: all 8 combinations passed")

// Executable event-order harness using the same production ticket gate. Queued
// deliveries retain the ticket installed on the player before the user intent.
struct PlaybackHarness {
    var gate = ReqGramPlaybackCompletionGate()
    var installed: UInt64 = 0
    var queued: [UInt64] = []
    var stops = 0
    var advances = 0
    var pendingNavigation: String?
    var enabled = true

    mutating func install() { installed = gate.arm() }
    mutating func enqueueEnd() { queued.append(installed) }
    mutating func navigate(_ direction: String) {
        gate.invalidate()
        pendingNavigation = direction
    }
    mutating func replay() {
        gate.invalidate()
        if pendingNavigation == nil { install() }
    }
    mutating func pause() { gate.invalidate() }
    mutating func deliver() {
        let ticket = queued.removeFirst()
        guard gate.consume(ticket) else { return }
        if enabled {
            gate.invalidate() // SharedMediaPlayer.stop()
            stops += 1
            pendingNavigation = nil
        } else {
            advances += 1
            pendingNavigation = "next"
        }
    }
}

for direction in ["next", "previous"] {
    var h = PlaybackHarness()
    h.install()
    h.enqueueEnd()
    h.navigate(direction) // Playlist is still on the old item/loading.
    h.deliver()
    precondition(h.stops == 0 && h.pendingNavigation == direction)
    h.install() // Navigation result arrives later.
    h.enqueueEnd()
    h.deliver()
    precondition(h.stops == 1)
}

do {
    var h = PlaybackHarness()
    h.install()
    h.enqueueEnd()
    h.replay() // Seek/play on the same media object, without item replacement.
    h.deliver()
    precondition(h.stops == 0)
    h.enqueueEnd()
    h.deliver()
    precondition(h.stops == 1) // New replay still stops when it really finishes.
}

for enabled in [false, true] {
    var h = PlaybackHarness()
    h.enabled = enabled
    h.install()
    h.enqueueEnd()
    h.enqueueEnd()
    h.deliver()
    h.deliver()
    precondition(h.stops == (enabled ? 1 : 0))
    precondition(h.advances == (enabled ? 0 : 1))
}

do {
    var old = PlaybackHarness()
    old.install()
    old.enqueueEnd()
    old.gate.invalidate() // MediaManager stops old player before replacement.
    var replacement = PlaybackHarness()
    replacement.install()
    old.deliver()
    precondition(old.stops == 0 && replacement.stops == 0)
    replacement.enqueueEnd()
    replacement.deliver()
    precondition(replacement.stops == 1)
}
print("Completion ordering: pending next/previous, replay, duplicates, replacement passed")

for direction in ["next", "previous"] {
    var h = PlaybackHarness()
    h.install()
    h.navigate(direction)
    h.replay() // Play/seek must not arm the old item while navigation loads.
    h.enqueueEnd()
    h.deliver()
    precondition(h.stops == 0 && h.pendingNavigation == direction)
}
do {
    var h = PlaybackHarness()
    h.install()
    h.enqueueEnd()
    h.pause()
    h.deliver()
    h.enqueueEnd() // Even a later callback from the paused item stays invalid.
    h.deliver()
    precondition(h.stops == 0)
    h.replay()
    h.enqueueEnd()
    h.deliver()
    precondition(h.stops == 1)
}
print("Completion controls: pending navigation rearm and pause/resume passed")
