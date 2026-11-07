import Foundation

/// Snapshot undo/redo (ARCHITECTURE §5.3). Before each edit the previous value is pushed; a continuous
/// gesture (slider drag, block drag) opens a *coalescing group* so the whole gesture is one undo step.
public struct UndoHistory<Value: Equatable & Sendable>: Sendable {
    public let limit: Int
    public private(set) var undoStack: [Value] = []
    public private(set) var redoStack: [Value] = []
    private var groupOpen = false
    private var groupRecorded = false

    public init(limit: Int = 200) { self.limit = limit }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Call before changing `current`. Inside an open group only the first change is recorded.
    public mutating func willChange(from current: Value) {
        if groupOpen && groupRecorded { return }
        undoStack.append(current)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
        if groupOpen { groupRecorded = true }
    }

    public mutating func beginGroup() {
        groupOpen = true
        groupRecorded = false
    }

    public mutating func endGroup() {
        groupOpen = false
        groupRecorded = false
    }

    /// Returns the value to restore, or nil.
    public mutating func undo(current: Value) -> Value? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public mutating func redo(current: Value) -> Value? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
