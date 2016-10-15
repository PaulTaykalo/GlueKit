//
//  Signal.swift
//  GlueKit
//
//  Created by Károly Lőrentey on 2015-11-30.
//  Copyright © 2015 Károly Lőrentey. All rights reserved.
//

import Foundation

internal protocol SignalDelegate: class {
    associatedtype SignalValue
    func start(_ signal: Signal<SignalValue>)
    func stop(_ signal: Signal<SignalValue>)
}

/// Holds a strong reference to a value that may not be ready for consumption yet.
private enum Ripening<Value> {
    case ripe(Value)
    case unripe(Value)

    var ripeValue: Value? {
        if case .ripe(let value) = self  {
            return value
        }
        else {
            return nil
        }
    }

    mutating func ripen() {
        if case .unripe(let value) = self {
            self = .ripe(value)
        }
    }
}

private enum PendingItem<Value> {
    case sendValue(Value)
    case ripenSinkWithID(ConnectionID)
}

/// A Signal is both a source and a sink. Sending a value to a signal's sink forwards it to all sinks that are 
/// currently connected to the signal. The signal's sink is named "send", and it is available as a direct method.
///
/// The Five Rules of Signal:
///
/// 0. Signal only sends values to sinks that it receives via Signal.send(). All such values are forwarded to 
///    sinks connected at the time of the send (if any).
/// 1. Sends are serialized. Signal defines a strict order between the values sent to it, forming a single 
///    sequence of values.
/// 2. All sinks get the same values. Each sink receives a subsequence of the Signal's value sequence. No reordering,
///    no skipping, no duplicates.
/// 3. Connections are serialized with sends. Each sink's value subsequence starts with the first value that 
///    was (started to be) sent after it was connected (if any).
/// 4. Disconnection is immediate. No new value is sent to a sink after its connection has finished disconnecting.
///
/// Some implementation notes:
///
/// The simplest nontrivial way to implement these rules is to make the Signal synchronous by serializing send() 
/// using a lock -- this is the way chosen by ReactiveCocoa and RxSwift. This makes reentrant send() calls deadlock, 
/// but that's probably a good thing. (You can emulate reentrant sends by scheduling an asyncronous send; however,
/// that can visibly break value ordering.)
///
/// As an experiment, this particular Signal implementation allows send() to be called from any thread at any 
/// time---including reentrant send()s from a sink that is currently being executed by it. To ensure the rule set
/// above, reentrant and concurrent sends and connects are asynchronous. They are ordered in a queue and performed 
/// at the end of the active send that first entered the signal. This implementation never invokes sinks recursively 
/// inside another sink invocation.
///
/// For reference, KVO's analogue to Signal in Foundation supports reentrancy, but its send() is synchronous. There 
/// is no way to satisy the above rules in a system like that. KVO's designers chose to resolve this by always calling 
/// observers with the latest value of the observed key path. That's a nice pragmatic solution in the face of 
/// reentrancy, but it only makes sense when you have the concept of a current value, which Signal doesn't. 
/// (Although Variable does.)
///
public class Signal<Value>: SourceType, SinkType {
    public typealias SourceValue = Value
    public typealias SinkValue = Value

    private let lock = Lock()
    private var sending = false
    private var sinks: Dictionary<ConnectionID, Ripening<Sink<Value>>> = [:]
    private var pendingItems: [PendingItem<Value>] = []

    /// A closure that is run whenever this signal transitions from an empty signal to one having a single connection.
    /// (Executed on the thread that connects the first sink.)
    internal let startCallback: (Signal<Value>) -> Void

    /// A closure that is run whenever this signal transitions from having at least one connection to having no 
    /// connections. (Executed on the thread that disconnects the last sink.)
    internal let stopCallback: (Signal<Value>) -> Void

    /// @param start: A closure that is run whenever this signal transitions from an empty signal to one having a 
    ///     single connection. (Executed on the thread that connects the first sink.)
    /// @param stop: A closure that is run whenever this signal transitions from having at least one connection to
    ///     having no connections. (Executed on the thread that disconnects the last sink.)
    internal init(start: @escaping (Signal<Value>) -> Void, stop: @escaping (Signal<Value>) -> Void) {
        self.startCallback = start
        self.stopCallback = stop
    }

    internal convenience init(delegateCallback: @escaping (_ signal: Signal<Value>, _ started: Bool) -> Void) {
        self.init(
            start: { s in delegateCallback(s, true) },
            stop: { s in delegateCallback(s, false) })
    }

    internal convenience init<Delegate: SignalDelegate>(delegate: Delegate) where Delegate.SignalValue == Value {
        self.init(
            start: { [weak delegate] s in delegate?.start(s) },
            stop: { [weak delegate] s in delegate?.stop(s) })
    }

    internal convenience init<Delegate: SignalDelegate>(stronglyHeldDelegate delegate: Delegate) where Delegate.SignalValue == Value {
        self.init(
            start: { s in delegate.start(s) },
            stop: { s in delegate.stop(s) })
    }

    public convenience init() {
        self.init(start: { s in }, stop: { s in })
    }

    /// Atomically enter sending state if the signal wasn't already in it.
    /// @returns true if the signal entered sending state due to this call.
    private func _enterSendingState() -> Bool {
        return lock.withLock {
            if sending { return false }
            sending = true
            return true
        }
    }

    /// Atomically return the pending value that needs to be sent next, or nil. 
    /// If there are no more values, exit the sending state.
    private func _nextValueToSendOrElseLeaveSendingState() -> Value? {
        return lock.withLock {
            assert(self.sending)
            while case .some(let item) = self.pendingItems.first {
                self.pendingItems.removeFirst()
                switch item {
                case .sendValue(let value):
                    if !self.sinks.isEmpty { // Skip value if there are no sinks.
                        // Send the next value to all ripe sinks.
                        return value
                    }
                case .ripenSinkWithID(let id):
                    self.sinks[id]?.ripen()
                }
            }
            // There are no more items to process.
            self.sending = false
            return nil
        }
    }

    /// Synchronously send a value to all connected sinks.
    private func _sendValueNow(_ value: Value) {
        assert(lock.withLock { sending })

        // Note that sinks are allowed to freely add or remove connections. 
        // This loop is constructed to support this correctly:
        // - New sinks added while we are sending a value will not fire.
        // - Sinks removed during the iteration will not fire.
        for (id, _) in lock.withLock({ return self.sinks }) {
            if let sink = lock.withLock({ return self.sinks[id]?.ripeValue }) {
                sink.receive(value)
            }
        }
    }

    /// Send a value to all sinks currently connected to this Signal. The sinks are executed in undefined order.
    ///
    /// The sinks are normally executed synchronously. However, when two or more threads are sending values at the 
    /// same time, or when a connected sink sends a value back to this same signal, then only the send() arriving 
    /// first is synchronous; the rest are performed asynchronously on the thread of the first send(), before the 
    /// first send() returns.
    ///
    /// You may safely call this method from any thread, provided that the sinks are OK with running there.
    public func send(_ value: Value) {
        sendLater(value)
        sendNow()
    }

    /// When used as a sink, a Signal forwards all received values to its connected sinks in turn.
    public func receive(_ value: Value) {
        send(value)
    }

    /// Append value to the queue of pending values. The value will be sent by a send() or sendNow() invocation.
    /// (If sendNow() is already running (recursively up the call stack, or on another thread), then the value will be
    /// sent by that invocation. If not, the first upcoming send will send the value.)
    ///
    /// Calls to sendLater() should always be followed by at least one call to sendNow().
    ///
    /// This construct is useful to control the ordering of notifications about changes to a value in the face of 
    /// concurrent modifications, without calling send() inside a lock. For example, here is a thread-safe, reentrant 
    /// counter that guarantees to send increasing counts, without holding a lock during sending:
    ///
    /// ```
    /// public struct Counter {
    ///     private let mutex = Mutex()
    ///     private var count: Int = 0
    ///     private let signal = Signal<Int>()
    ///
    ///     public var source: Source<Int> { return signal.source }
    ///
    ///     public mutating func increment() {
    ///         let value: Int = mutex.withLock {
    ///             let v = ++count
    ///             signal.sendLater(v)
    ///             return v
    ///         }
    ///         signal.sendNow()
    ///         return value
    ///     }
    /// }
    /// ```
    internal func sendLater(_ value: Value) {
        lock.withLock {
            self.pendingItems.append(.sendValue(value))
        }
    }

    /// Send all pending values immediately, or do nothing if the signal is already sending values elsewhere.
    /// (On another thread, or if this is a recursive call of sendNow on the current thread.)
    internal func sendNow() {
        if _enterSendingState() {
            while let value = _nextValueToSendOrElseLeaveSendingState() {
                _sendValueNow(value)
            }
        }
    }

    public func connect(_ sink: Sink<Value>) -> Connection {
        let c = Connection(callback: self.disconnect) // c now holds a strong reference to self.
        let id = c.connectionID
        let first: Bool = lock.withLock {
            let first = self.sinks.isEmpty
            if self.pendingItems.isEmpty {
                self.sinks[id] = .ripe(sink)
            }
            else {
                // Values that are currently pending should not be sent to this sink, but any future values should be.
                self.sinks[id] = .unripe(sink)
                self.pendingItems.append(.ripenSinkWithID(id))
            }
            return first
        }

        // c is holding us, and we now hold a strong reference to the sink, so c holds both us and the sink.

        if first {
            self.startCallback(self)
        }
        return c
    }

    public var isConnected: Bool { return lock.withLock { !self.sinks.isEmpty } }

    private func disconnect(_ id: ConnectionID) {
        let last = lock.withLock { () -> Bool in
            return self.sinks.removeValue(forKey: id) != nil && self.sinks.isEmpty
        }
        if last {
            self.stopCallback(self)
        }
    }
}

