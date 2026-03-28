//
//  HumanTypingEvaluator.swift
//  Sur
//
//  Evaluates keystroke patterns to determine if text was typed by a human.
//  Uses multiple heuristics including timing, rhythm, and coordinate analysis.
//

import Foundation

/// Evaluates typing patterns to determine human authenticity
public struct HumanTypingEvaluator {
    
    // MARK: - Constants
    
    /// Minimum reasonable inter-key interval (20ms - very fast typing)
    private static let minInterKeyInterval: Double = 20.0
    
    /// Maximum reasonable inter-key interval (2000ms - slow/distracted typing)
    private static let maxInterKeyInterval: Double = 2000.0
    
    /// Expected average typing speed range (100-400ms between keys)
    private static let avgInterKeyIntervalMin: Double = 100.0
    private static let avgInterKeyIntervalMax: Double = 400.0
    
    /// Minimum coefficient of variation for natural typing (humans vary their timing)
    private static let minTimingVariation: Double = 0.15
    
    /// Maximum coordinate movement between consecutive keys (normalized 0-1)
    private static let maxCoordinateJump: Double = 0.8
    
    /// Weight factors for different evaluation criteria
    private static let timingWeight: Double = 0.35
    private static let variationWeight: Double = 0.25
    private static let coordinateWeight: Double = 0.20
    private static let patternWeight: Double = 0.20
    
    // MARK: - Public Interface
    
    /// Evaluate a keystroke session for human typing probability
    /// - Parameter session: The keystroke session to evaluate
    /// - Returns: Human typing probability (0-100)
    public static func evaluate(session: KeystrokeSession) -> Double {
        let keystrokes = session.signedKeystrokes.map { $0.keystroke }
        
        // Need at least 2 keystrokes to evaluate
        guard keystrokes.count >= 2 else {
            return 100.0 // Single keystroke is trivially human
        }
        
        // Calculate individual scores
        let timingScore = evaluateTimingPatterns(keystrokes: keystrokes)
        let variationScore = evaluateTimingVariation(keystrokes: keystrokes)
        let coordinateScore = evaluateCoordinatePatterns(keystrokes: keystrokes)
        let patternScore = evaluateTypingPatterns(keystrokes: keystrokes)
        
        // Weighted combination
        let totalScore = (timingScore * timingWeight +
                         variationScore * variationWeight +
                         coordinateScore * coordinateWeight +
                         patternScore * patternWeight) * 100.0
        
        // Clamp to 0-100
        return min(100.0, max(0.0, totalScore))
    }
    
    /// Get a detailed breakdown of the evaluation
    public static func evaluateDetailed(session: KeystrokeSession) -> HumanTypingAnalysis {
        let keystrokes = session.signedKeystrokes.map { $0.keystroke }
        
        guard keystrokes.count >= 2 else {
            return HumanTypingAnalysis(
                overallScore: 100.0,
                timingScore: 100.0,
                variationScore: 100.0,
                coordinateScore: 100.0,
                patternScore: 100.0,
                averageInterKeyInterval: 0,
                intervalVariation: 0,
                totalDuration: 0,
                keystrokeCount: keystrokes.count
            )
        }
        
        let timingScore = evaluateTimingPatterns(keystrokes: keystrokes) * 100
        let variationScore = evaluateTimingVariation(keystrokes: keystrokes) * 100
        let coordinateScore = evaluateCoordinatePatterns(keystrokes: keystrokes) * 100
        let patternScore = evaluateTypingPatterns(keystrokes: keystrokes) * 100
        
        let intervals = calculateInterKeyIntervals(keystrokes: keystrokes)
        let avgInterval = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
        let variation = calculateCoefficientOfVariation(intervals)
        
        let totalDuration = keystrokes.last!.timestamp - keystrokes.first!.timestamp
        
        let overallScore = (timingScore * timingWeight +
                          variationScore * variationWeight +
                          coordinateScore * coordinateWeight +
                          patternScore * patternWeight)
        
        return HumanTypingAnalysis(
            overallScore: min(100, max(0, overallScore)),
            timingScore: timingScore,
            variationScore: variationScore,
            coordinateScore: coordinateScore,
            patternScore: patternScore,
            averageInterKeyInterval: avgInterval,
            intervalVariation: variation,
            totalDuration: totalDuration,
            keystrokeCount: keystrokes.count
        )
    }
    
    // MARK: - Private Evaluation Methods
    
    /// Evaluate if timing patterns are within human range
    private static func evaluateTimingPatterns(keystrokes: [Keystroke]) -> Double {
        let intervals = calculateInterKeyIntervals(keystrokes: keystrokes)
        guard !intervals.isEmpty else { return 1.0 }
        
        var score = 1.0
        
        // Check if intervals are within reasonable range
        for interval in intervals {
            if interval < minInterKeyInterval {
                // Too fast - likely automated (penalty increases with speed)
                let penalty = (minInterKeyInterval - interval) / minInterKeyInterval
                score -= penalty * 0.3
            } else if interval > maxInterKeyInterval {
                // Very slow - might be distracted but still human, minor penalty
                let penalty = min((interval - maxInterKeyInterval) / maxInterKeyInterval, 0.5)
                score -= penalty * 0.1
            }
        }
        
        // Check average typing speed
        let avgInterval = intervals.reduce(0, +) / Double(intervals.count)
        if avgInterval < avgInterKeyIntervalMin {
            // Faster than typical human average
            let speedRatio = avgInterval / avgInterKeyIntervalMin
            score *= (0.5 + speedRatio * 0.5)
        } else if avgInterval > avgInterKeyIntervalMax {
            // Slower than typical - still human, small adjustment
            let slowRatio = min(avgInterval / avgInterKeyIntervalMax, 3.0)
            score *= max(0.8, 1.0 - (slowRatio - 1.0) * 0.1)
        }
        
        return max(0, score)
    }
    
    /// Evaluate timing variation (humans have natural variation)
    private static func evaluateTimingVariation(keystrokes: [Keystroke]) -> Double {
        let intervals = calculateInterKeyIntervals(keystrokes: keystrokes)
        guard intervals.count >= 3 else { return 1.0 }
        
        let cv = calculateCoefficientOfVariation(intervals)
        
        // Humans typically have CV of 0.2-0.6 for typing
        if cv < minTimingVariation {
            // Too consistent - likely automated
            return cv / minTimingVariation * 0.7
        } else if cv > 1.0 {
            // Very inconsistent - might be distracted human or erratic input
            return max(0.5, 1.0 - (cv - 1.0) * 0.2)
        }
        
        // Good variation range
        return 1.0
    }
    
    /// Evaluate coordinate movement patterns
    private static func evaluateCoordinatePatterns(keystrokes: [Keystroke]) -> Double {
        guard keystrokes.count >= 2 else { return 1.0 }
        
        var score = 1.0
        var impossibleMoves = 0
        var perfectlyStationary = 0
        
        // Normalize coordinates to 0-1 range
        let xCoords = keystrokes.map { $0.xCoordinate }
        let yCoords = keystrokes.map { $0.yCoordinate }
        
        let xRange = (xCoords.max() ?? 0) - (xCoords.min() ?? 0)
        let yRange = (yCoords.max() ?? 0) - (yCoords.min() ?? 0)
        
        for i in 1..<keystrokes.count {
            let prev = keystrokes[i-1]
            let curr = keystrokes[i]
            
            let xDiff = abs(curr.xCoordinate - prev.xCoordinate)
            let yDiff = abs(curr.yCoordinate - prev.yCoordinate)
            
            // Check for impossibly fast coordinate changes relative to time
            let timeDiff = Double(curr.timestamp - prev.timestamp)
            
            // Normalize distance
            let normalizedXDiff = xRange > 0 ? xDiff / xRange : 0
            let normalizedYDiff = yRange > 0 ? yDiff / yRange : 0
            let normalizedDist = sqrt(normalizedXDiff * normalizedXDiff + normalizedYDiff * normalizedYDiff)
            
            // Check for suspicious patterns
            if normalizedDist > maxCoordinateJump && timeDiff < 50 {
                // Large coordinate jump in very short time
                impossibleMoves += 1
            }
            
            if xDiff < 0.001 && yDiff < 0.001 && prev.key != curr.key {
                // Same position for different keys - suspicious
                perfectlyStationary += 1
            }
        }
        
        // Apply penalties
        let impossibleRatio = Double(impossibleMoves) / Double(keystrokes.count - 1)
        score -= impossibleRatio * 0.5
        
        let stationaryRatio = Double(perfectlyStationary) / Double(keystrokes.count - 1)
        if stationaryRatio > 0.8 {
            // Most keystrokes at same position - very suspicious
            score -= stationaryRatio * 0.4
        }
        
        return max(0, score)
    }
    
    /// Evaluate natural typing patterns (pauses, bursts, etc.)
    private static func evaluateTypingPatterns(keystrokes: [Keystroke]) -> Double {
        let intervals = calculateInterKeyIntervals(keystrokes: keystrokes)
        guard intervals.count >= 5 else { return 1.0 }
        
        var score = 1.0
        
        // Check for natural pauses (thinking, words)
        let pauseThreshold = 300.0 // ms
        let pauses = intervals.filter { $0 > pauseThreshold }.count
        let pauseRatio = Double(pauses) / Double(intervals.count)
        
        // Humans typically pause 10-30% of the time
        if pauseRatio < 0.05 {
            // Very few pauses - might be automated
            score *= 0.8
        } else if pauseRatio > 0.5 {
            // Very many pauses - still human but slow
            score *= 0.9
        }
        
        // Check for typing bursts (consecutive fast keys)
        let burstThreshold = 150.0 // ms
        var burstLengths: [Int] = []
        var currentBurst = 0
        
        for interval in intervals {
            if interval < burstThreshold {
                currentBurst += 1
            } else {
                if currentBurst > 0 {
                    burstLengths.append(currentBurst)
                }
                currentBurst = 0
            }
        }
        if currentBurst > 0 {
            burstLengths.append(currentBurst)
        }
        
        // Humans typically have varied burst lengths
        if !burstLengths.isEmpty {
            let avgBurst = Double(burstLengths.reduce(0, +)) / Double(burstLengths.count)
            let burstVariation = calculateCoefficientOfVariation(burstLengths.map { Double($0) })
            
            if avgBurst > 20 && burstVariation < 0.1 {
                // Very long consistent bursts - suspicious
                score *= 0.7
            }
        }
        
        return max(0, score)
    }
    
    // MARK: - Utility Methods
    
    /// Calculate inter-key intervals in milliseconds
    private static func calculateInterKeyIntervals(keystrokes: [Keystroke]) -> [Double] {
        guard keystrokes.count >= 2 else { return [] }
        
        var intervals: [Double] = []
        for i in 1..<keystrokes.count {
            let interval = Double(keystrokes[i].timestamp - keystrokes[i-1].timestamp)
            intervals.append(interval)
        }
        return intervals
    }
    
    /// Calculate coefficient of variation (std dev / mean)
    private static func calculateCoefficientOfVariation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return 0 }
        
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        let stdDev = sqrt(variance)
        
        return stdDev / mean
    }
}

// MARK: - Analysis Result

/// Detailed analysis of human typing probability
public struct HumanTypingAnalysis: Codable {
    /// Overall human typing score (0-100)
    public let overallScore: Double
    
    /// Score for timing patterns (0-100)
    public let timingScore: Double
    
    /// Score for timing variation (0-100)
    public let variationScore: Double
    
    /// Score for coordinate patterns (0-100)
    public let coordinateScore: Double
    
    /// Score for natural typing patterns (0-100)
    public let patternScore: Double
    
    /// Average time between keystrokes (ms)
    public let averageInterKeyInterval: Double
    
    /// Variation coefficient of intervals
    public let intervalVariation: Double
    
    /// Total typing duration (ms)
    public let totalDuration: Int64
    
    /// Number of keystrokes analyzed
    public let keystrokeCount: Int
}
