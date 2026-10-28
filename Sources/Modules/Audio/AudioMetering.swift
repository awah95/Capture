import AVFoundation
import Foundation

/// Returns the linear RMS amplitude of normalized floating-point PCM, clamped to 0...1.
///
/// This is equivalent to converting average power to dB and back with
/// `pow(10, dB / 20)`, without the unnecessary logarithmic round trip.
func normalizedRMS(samples: UnsafeBufferPointer<Float>) -> Double {
    guard !samples.isEmpty else { return 0 }

    var sumOfSquares = 0.0
    for sample in samples {
        let value = Double(sample)
        sumOfSquares += value * value
    }

    return min(1, max(0, sqrt(sumOfSquares / Double(samples.count))))
}

func normalizedRMS(samples: [Float]) -> Double {
    samples.withUnsafeBufferPointer { normalizedRMS(samples: $0) }
}

// `AudioRecordingSink` used to live here, owning the tap's file writer *and* the meter
// counters on behalf of a main-actor engine. Both responsibilities now have their own
// homes — `FLACWriter` for the file, the engine's audio-queue-confined level throttle
// for metering — and the engine itself is no longer main-actor isolated, so the sink
// was deleted rather than carried forward.
