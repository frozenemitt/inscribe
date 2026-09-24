import AVFoundation
import Foundation
import SwiftUI

public struct AudioData: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer
    var time: AVAudioTime
}

extension AVAudioPlayerNode {
    var currentTime: TimeInterval {
        guard let nodeTime: AVAudioTime = self.lastRenderTime,
            let playerTime: AVAudioTime = self.playerTime(forNodeTime: nodeTime)
        else { return 0 }

        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }
}
