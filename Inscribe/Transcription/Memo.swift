import Foundation
import SwiftData
import SwiftUI

// MARK: - Diarization Types

struct DiarizationResult {
    struct Segment {
        let speakerId: String
        let startTimeSeconds: Double
        let endTimeSeconds: Double
    }
    
    let segments: [Segment]
}

// MARK: - Memo Model

@Model
final class Memo {
    var text: AttributedString
    var url: URL?
    var isDone: Bool
    var createdAt: Date
    
    @Relationship(deleteRule: .cascade)
    var speakerSegments: [SpeakerSegment]
    
    init(text: AttributedString = "", url: URL? = nil, isDone: Bool = false) {
        self.text = text
        self.url = url
        self.isDone = isDone
        self.createdAt = Date()
        self.speakerSegments = []
    }
    
    func updateWithDiarizationResult(_ result: DiarizationResult, in context: ModelContext) {
        // Clear existing speaker segments
        speakerSegments.removeAll()
        
        // Create new speaker segments from diarization result
        for segment in result.segments {
            let speakerSegment = SpeakerSegment(
                speakerId: segment.speakerId,
                startTime: TimeInterval(segment.startTimeSeconds),
                endTime: TimeInterval(segment.endTimeSeconds),
                text: ""
            )
            speakerSegments.append(speakerSegment)
            context.insert(speakerSegment)
        }
    }
}

@Model
final class SpeakerSegment {
    var speakerId: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    
    init(speakerId: String, startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.speakerId = speakerId
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}
