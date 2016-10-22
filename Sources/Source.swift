//
//  Source.swift
//  GlueKit
//
//  Created by Károly Lőrentey on 2015-11-30.
//  Copyright © 2015 Károly Lőrentey. All rights reserved.
//

/// A Source is an entity that is able to produce values to other entities (called Sinks) that are connected to it.
/// A source can be an observable value (see Variable<Value>), a KVO-compatible key path on an object 
/// (see NSObject.sourceForKeyPath), a notification (see NSNotificationCenter.sourceForNotification), 
/// a timer (see TimerSource), etc. etc.
///
/// Sources implement the `SourceType` protocol. It only has a single method, `connect`; it can be used to subscribe
/// new sinks to values produced by this source.
///
/// `SourceType` is a protocol with an associated value, which can be sometimes inconvenient to work with. 
/// GlueKit provides the struct `Source<Value>` to represent a type-erased source.
///
/// A source is intended to be equivalent to a read-only propery. Therefore, while a source typically has a mechanism
/// for sending values, this is intentionally outside the scope of `SourceType`. (But see `Signal<Value>`).
///
/// We represent a source by a struct holding the subscription closure; this allows extensions on it, which is convenient. 
/// GlueKit provides built-in extension methods for transforming sources to other kinds of sources.
///
public protocol SourceType {
    /// The type of values produced by this source.
    associatedtype Value

    /// Subscribe `sink` to this source, i.e., retain the sink and start calling its `receive` function 
    /// whenever this source produces a value. 
    /// The subscription remains active until `remove` is called with an identical sink.
    ///
    /// - Returns: True iff the source had no subscribers before this call.
    /// - SeeAlso: `connect`, `remove`
    @discardableResult
    func add<Sink: SinkType>(_ sink: Sink) -> Bool where Sink.Value == Value

    /// Remove `sink`'s subscription to this source, i.e., stop calling the sink's `receive` function and release it.
    /// The subscription remains active until `remove` is called with an identical sink.
    ///
    /// - Returns: True iff this was the last subscriber of this source.
    /// - SeeAlso: `connect`, `add`
    @discardableResult
    func remove<Sink: SinkType>(_ sink: Sink) -> Bool where Sink.Value == Value

    /// A type-erased representation of this source.
    var source: AnySource<Value> { get }
}


extension SourceType {
    public var source: AnySource<Value> {
        return AnySource(box: SourceBox(self))
    }
}

/// A Source is an entity that is able to produce values to other entities (called Sinks) that are connected to it.
/// A source can be an observable value (see Variable<Value>), a KVO-compatible key path on an object
/// (see NSObject.sourceForKeyPath), a notification (see NSNotificationCenter.sourceForNotification),
/// a timer (see TimerSource), etc. etc.
///
/// Sources implement the `SourceType` protocol. It only has a single method, `connect`; it can be used to subscribe
/// new sinks to values produced by this source.
///
/// `SourceType` is a protocol with an associated value, which is sometimes inconvenient to work with. GlueKit
/// provides the struct `Source<Value>` to represent a type-erased source.
///
/// A source is intended to be equivalent to a read-only propery. Therefore, while a source typically has a mechanism
/// for sending values, this is intentionally outside the scope of `SourceType`. (But see `Signal<Value>`).
///
/// We represent a source by a struct holding the subscription closure; this allows extensions on it, which is convenient.
/// GlueKit provides built-in extension methods for transforming sources to other kinds of sources.
///
public struct AnySource<Value>: SourceType {
    private let box: _AbstractSourceBase<Value>

    internal init(box: _AbstractSourceBase<Value>) {
        self.box = box
    }

    @discardableResult
    public func add<Sink: SinkType>(_ sink: Sink) -> Bool where Sink.Value == Value {
        return box.add(sink)
    }

    @discardableResult
    public func remove<Sink: SinkType>(_ sink: Sink) -> Bool where Sink.Value == Value {
        return box.remove(sink)
    }

    public var source: AnySource<Value> { return self }
}

open class _AbstractSourceBase<Value>: SourceType {
    @discardableResult
    open func add<Sink: SinkType>(_ sink: Sink) -> Bool where Sink.Value == Value {
        abstract()
    }

    @discardableResult
    open func remove<Sink: SinkType>(_ sink: Sink) -> Bool where Sink.Value == Value {
        abstract()
    }

    public final var source: AnySource<Value> {
        return AnySource(box: self)
    }
}

internal class SourceBox<Base: SourceType>: _AbstractSourceBase<Base.Value> {
    typealias Value = Base.Value

    let base: Base

    init(_ base: Base) {
        self.base = base
    }

    @discardableResult
    override func add<Sink: SinkType>(_ sink: Sink) -> Bool where Sink.Value == Value {
        return base.add(sink)
    }

    @discardableResult
    override func remove<Sink: SinkType>(_ sink: Sink) -> Bool where Sink.Value == Value {
        return base.add(sink)
    }
}
