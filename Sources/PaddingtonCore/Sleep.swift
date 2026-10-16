import Foundation

/// [sleep]: the pad's lights go dark after `after` seconds without a press, turn or button (to save the pad's
/// battery). The next press only wakes it: that control's release is swallowed too, and a knob that woke it is
/// ignored for a moment so the rest of the same turn doesn't scroll.
public struct PadSleep {
    public var after: Double                        // seconds without pad input; 0 = never sleeps
    public private(set) var asleep = false
    var lastInput: Double
    var swallowed: Set<String> = []                 // pressed to wake: their release does nothing either
    var quietUntil: [String: Double] = [:]          // knobs turned to wake: the rest of that turn does nothing

    public init(after: Double, now: Double) { self.after = after; lastInput = now }

    /// Pad input: the events left for the engine (none when they only woke the pad), and whether it woke.
    public mutating func input(_ events: [ControlEvent], now: Double) -> (events: [ControlEvent], woke: Bool) {
        lastInput = now
        if asleep {
            asleep = false
            for ev in events {
                switch ev {
                case .down(let c): swallowed.insert(c)
                case .turn(let c, _): quietUntil[c] = now + 0.5
                case .up: break
                }
            }
            return ([], true)
        }
        let left = events.filter { ev in
            switch ev {
            case .up(let c): return swallowed.remove(c) == nil
            case .turn(let c, _): return now >= quietUntil[c] ?? 0
            case .down: return true
            }
        }
        return (left, false)
    }

    /// Every second: true when the pad just fell asleep.
    public mutating func check(now: Double) -> Bool {
        guard after > 0, !asleep, now - lastInput >= after else { return false }
        sleep()
        return true
    }

    public mutating func sleep() { asleep = true; swallowed = []; quietUntil = [:] }

    /// Awake without a press (an agent needs you): the next press acts as usual.
    public mutating func wake(now: Double) { asleep = false; lastInput = now }
}
