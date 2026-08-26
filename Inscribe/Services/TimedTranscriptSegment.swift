import Foundation

/// A run of transcribed text and the stretch of audio it came from.
///
/// The bridge between two independent analyses of the same recording: the
/// transcriber knows *what* was said and when, the diarizer knows *who* was
/// speaking and when. Time is the only thing they share.
struct TimedTranscriptSegment: Sendable, Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval

    /// The instant used to decide which speaker owns this run.
    ///
    /// The midpoint, not the start: a run beginning a hair before the diarizer marks
    /// the handover would otherwise be credited to the previous speaker.
    var midpoint: TimeInterval { start + (end - start) / 2 }
}
