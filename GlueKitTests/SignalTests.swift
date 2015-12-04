//
//  SignalTests.swift
//  GlueKit
//
//  Created by Károly Lőrentey on 2015-11-30.
//  Copyright © 2015 Károly Lőrentey. All rights reserved.
//

import XCTest
@testable import GlueKit

class SignalTests: XCTestCase {

    //MARK: Test simple stuff

    func testSimpleConnection() {
        let signal = Signal<Int>()

        signal.send(1)

        var r = [Int]()
        let connection = signal.connect { i in r.append(i) }

        signal.send(2)
        signal.send(3)
        signal.send(4)

        connection.disconnect()

        signal.send(5)

        XCTAssertEqual(r, [2, 3, 4])
    }

    func testReleasingConnectionDisconnects() {
        let signal = Signal<Int>()
        var values = [Int]()
        var c: Connection? = nil

        c = signal.connect { values.append($0) }
        signal.send(1)
        c = nil
        signal.send(2)

        XCTAssertEqual(values, [1])
        noop(c)
    }

    func testDuplicateDisconnect() {
        let signal = Signal<Int>()

        let c = signal.connect { i in }

        // It is OK to call disconnect twice.
        c.disconnect()
        c.disconnect()
    }

    func testMultipleConnections() {
        let signal = Signal<Int>()

        signal.send(1)

        var a = [Int]()
        let c1 = signal.connect { i in a.append(i) }

        signal.send(2)

        var b = [Int]()
        let c2 = signal.connect { i in b.append(i) }

        signal.send(3)

        c1.disconnect()

        signal.send(4)

        c2.disconnect()

        signal.send(5)

        XCTAssertEqual(a, [2, 3])
        XCTAssertEqual(b, [3, 4])
    }

    //MARK: Test memory management

    func testConnectionRetainsTheSignal() {
        var values = [Int]()
        weak var weakSignal: Signal<Int>? = nil
        weak var weakConnection: Connection? = nil
        do {
            let connection: Connection
            do {
                let signal = Signal<Int>()
                weakSignal = signal
                connection = signal.connect { i in values.append(i) }
                weakConnection = .Some(connection)

                signal.send(1)
            }

            XCTAssertNotNil(weakSignal)
            XCTAssertNotNil(weakConnection)
            noop(connection)
        }
        XCTAssertNil(weakSignal)
        XCTAssertNil(weakConnection)
        XCTAssertEqual(values, [1])
    }

    func testDisconnectingConnectionReleasesResources() {
        weak var weakSignal: Signal<Int>? = nil
        weak var weakResource: NSMutableArray? = nil

        let connection: Connection
        do {
            let signal = Signal<Int>()
            weakSignal = signal

            let resource = NSMutableArray()
            weakResource = resource

            connection = signal.connect { i in
                resource.addObject(i)
            }
            signal.send(1)
        }

        XCTAssertNotNil(weakSignal)
        XCTAssertNotNil(weakResource)

        XCTAssertEqual(weakResource, NSArray(object: 1))

        connection.disconnect()

        XCTAssertNil(weakSignal)
        XCTAssertNil(weakResource)
    }

    func testSourceDoesNotRetainConnection() {
        var values = [Int]()
        weak var weakConnection: Connection? = nil
        let signal = Signal<Int>()
        do {
            let connection = signal.connect { values.append($0) }
            weakConnection = connection

            signal.send(1)
            noop(connection)
        }

        signal.send(2)
        XCTAssertNil(weakConnection)

        XCTAssertEqual(values, [1])
    }

    //MARK: Test sinks adding and removing connections

    func testAddingAConnectionInASink() {
        let signal = Signal<Int>()

        var v1 = [Int]()
        var c1: Connection? = nil

        var v2 = [Int]()
        var c2: Connection? = nil

        signal.send(1)

        c1 = signal.connect { i in
            v1.append(i)
            if c2 == nil {
                c2 = signal.connect { v2.append($0) }
            }
        }

        XCTAssertNil(c2)

        signal.send(2)

        XCTAssertNotNil(c2)

        signal.send(3)

        c1?.disconnect()
        c2?.disconnect()

        signal.send(4)

        XCTAssertEqual(v1, [2, 3])
        XCTAssertEqual(v2, [3])
    }

    func testRemovingConnectionWhileItIsBeingTriggered() {
        let signal = Signal<Int>()

        signal.send(1)

        var r = [Int]()

        var c: Connection? = nil
        c = signal.connect { i in
            r.append(i)
            c?.disconnect()
        }

        signal.send(2)
        signal.send(3)
        signal.send(4)

        XCTAssertEqual(r, [2])
    }

    func testRemovingNextConnection() {
        let signal = Signal<Int>()

        var r = [Int]()

        var c1: Connection? = nil
        var c2: Connection? = nil

        signal.send(0)

        // We don't know which connection fires first.
        // After disconnect() returns, the connection must not fire any more -- even if disconnect is called by a sink.

        c1 = signal.connect { i in
            r.append(i)
            c2?.disconnect()
            c2 = nil
        }

        c2 = signal.connect { i in
            r.append(i)
            c1?.disconnect()
            c1 = nil
        }

        XCTAssertTrue(c1 != nil && c2 != nil)

        signal.send(1)
        XCTAssertTrue((c1 == nil) != (c2 == nil))

        signal.send(2)
        signal.send(3)
        XCTAssertTrue((c1 == nil) != (c2 == nil))

        XCTAssertEqual(r, [1, 2, 3])
    }


    func testRemovingAndReaddingConnectionsAlternately() {
        // This is a weaker test of the semantics of connect/disconnect nested in sinks.
        let signal = Signal<Int>()

        var r1 = [Int]()
        var r2 = [Int]()

        var c1: Connection? = nil
        var c2: Connection? = nil

        var sink1: (Int->Void)!
        var sink2: (Int->Void)!

        sink1 = { i in
            r1.append(i)
            c1?.disconnect()
            c2 = signal.connect(sink2)
        }

        sink2 = { i in
            r2.append(i)
            c2?.disconnect()
            c1 = signal.connect(sink1)
        }

        c1 = signal.connect(sink1)
        for i in 1...6 {
            signal.send(i)
        }

        XCTAssertEqual(r1, [1, 3, 5])
        XCTAssertEqual(r2, [2, 4, 6])
    }

    func testSinkDisconnectingThenReconnectingItself() {
        // This is a weaker test of the semantics of connect/disconnect nested in sinks.
        let signal = Signal<Int>()

        var r = [Int]()
        var c: Connection? = nil
        var sink: (Int->Void)!

        sink = { i in
            r.append(i)
            c?.disconnect()
            c = signal.connect(sink)
        }
        c = signal.connect(sink)
        
        for i in 1...6 {
            signal.send(i)
        }

        c?.disconnect()

        XCTAssertEqual(r, [1, 2, 3, 4, 5, 6])
    }

    // MARK: Test didConnectFirstSink and didDisconnectLastSink
    func testFirstAndLastConnectCallbacksAreCalled() {
        var first = 0
        var last = 0
        let signal = Signal<Int>(didConnectFirstSink: { _ in first++ }, didDisconnectLastSink: { _ in last++ })

        XCTAssertEqual(first, 0)
        XCTAssertEqual(last, 0)

        signal.send(0)

        XCTAssertEqual(first, 0)
        XCTAssertEqual(last, 0)

        var count = 0
        let connection = signal.connect { i in count++ }

        XCTAssertEqual(first, 1)
        XCTAssertEqual(last, 0)
        XCTAssertEqual(count, 0)

        signal.send(1)

        XCTAssertEqual(first, 1)
        XCTAssertEqual(last, 0)
        XCTAssertEqual(count, 1)

        connection.disconnect()

        XCTAssertEqual(first, 1)
        XCTAssertEqual(last, 1)
        XCTAssertEqual(count, 1)

        signal.send(2)

        XCTAssertEqual(first, 1)
        XCTAssertEqual(last, 1)
        XCTAssertEqual(count, 1)
    }

    func testFirstAndLastConnectCallbacksAreCalledWithTheSignal() {

        var first: Signal<Int>? = nil
        var last: Signal<Int>? = nil

        let signal = Signal<Int>(
            didConnectFirstSink: { s in first = s },
            didDisconnectLastSink: { s in last = s })

        signal.send(0)

        var count = 0
        let connection = signal.connect { i in count++ }

        XCTAssert(first != nil && first === signal)

        connection.disconnect()

        XCTAssert(last != nil && last === signal)
    }

    func testFirstAndLastConnectCallbacksCanBeCalledMultipleTimes() {
        var first = 0
        var last = 0
        let signal = Signal<Int>(didConnectFirstSink: { _ in first++ }, didDisconnectLastSink: { _ in last++ })

        let c1 = signal.connect { i in }

        XCTAssertEqual(first, 1)
        XCTAssertEqual(last, 0)

        c1.disconnect()

        XCTAssertEqual(first, 1)
        XCTAssertEqual(last, 1)

        let c2 = signal.connect { i in }

        XCTAssertEqual(first, 2)
        XCTAssertEqual(last, 1)

        c2.disconnect()

        XCTAssertEqual(first, 2)
        XCTAssertEqual(last, 2)
    }

    func testFirstConnectCallbackIsOnlyCalledOnFirstConnections() {
        var first = 0
        let signal = Signal<Int>(didConnectFirstSink: { _ in first++ }, didDisconnectLastSink: { _ in })

        XCTAssertEqual(first, 0)

        let c1 = signal.connect { i in }

        XCTAssertEqual(first, 1)
        let c2 = signal.connect { i in }
        c1.disconnect()
        c2.disconnect()

        let c3 = signal.connect { i in }
        XCTAssertEqual(first, 2)
        c3.disconnect()
    }

    func testLastConnectCallbackIsOnlyCalledOnLastConnections() {
        var last = 0
        let signal = Signal<Int>(didConnectFirstSink: { _ in }, didDisconnectLastSink: { _ in last++ })

        XCTAssertEqual(last, 0)

        let c1 = signal.connect { i in }
        let c2 = signal.connect { i in }
        c1.disconnect()
        XCTAssertEqual(last, 0)
        c2.disconnect()
        XCTAssertEqual(last, 1)

        let c3 = signal.connect { i in }
        XCTAssertEqual(last, 1)
        c3.disconnect()
        XCTAssertEqual(last, 2)
    }

    //MARK: Test reentrant sends

    func testSinksAreNeverNested() {
        let signal = Signal<Int>()

        var s = ""

        let c = signal.connect { i in
            s += " (\(i)"
            if i > 0 {
                signal.send(i - 1) // This send is asynchronous. The value is sent at the end of the outermost send.
            }
            s += ")"
        }

        signal.send(3)
        c.disconnect()

        XCTAssertEqual(s, " (3) (2) (1) (0)")
    }

    func testSinksReceiveAllValuesSentAfterTheyConnectedEvenWhenReentrant() {
        var s = ""
        let signal = Signal<Int>()

        // Let's do an exponential cascade of decrements with two sinks:
        var values1 = [Int]()
        let c1 = signal.connect { i in
            values1.append(i)
            s += " (\(i)"
            if i > 0 {
                signal.send(i - 1)
            }
            s += ")"
        }

        var values2 = [Int]()
        let c2 = signal.connect { i in
            values2.append(i)
            s += " (\(i)"
            if i > 0 {
                signal.send(i - 1)
            }
            s += ")"
        }

        signal.send(2)

        // There should be no nesting and both sinks should receive all sent values, in correct order.
        XCTAssertEqual(values1, [2, 1, 1, 0, 0, 0, 0])
        XCTAssertEqual(values2, [2, 1, 1, 0, 0, 0, 0])
        XCTAssertEqual(s, " (2) (2) (1) (1) (1) (1) (0) (0) (0) (0) (0) (0) (0) (0)")
        
        c1.disconnect()
        c2.disconnect()
    }

    func testSinksDoNotReceiveValuesSentToTheSignalBeforeTheyWereConnected() {
        let signal = Signal<Int>()

        var values1 = [Int]()
        var values2 = [Int]()

        var c2: Connection? = nil
        let c1 = signal.connect { i in
            values1.append(i)
            if i == 3 && c2 == nil {
                signal.send(0) // This should not reach c2
                c2 = signal.connect { i in
                    values2.append(i)
                }
            }
        }
        signal.send(1)
        signal.send(2)
        signal.send(3)
        signal.send(4)
        signal.send(5)

        XCTAssertEqual(values1, [1, 2, 3, 0, 4, 5])
        XCTAssertEqual(values2, [4, 5])

        c1.disconnect()
        c2?.disconnect()
    }

    //MARK: sendLater / sendNow

    func testSendLaterSendsValueLater() {
        let signal = Signal<Int>()

        var r = [Int]()
        let c = signal.connect { r.append($0) }

        signal.sendLater(0)
        signal.sendLater(1)
        signal.sendLater(2)

        XCTAssertEqual(r, [])

        signal.sendNow()

        XCTAssertEqual(r, [0, 1, 2])

        c.disconnect()
    }

    func testSendLaterDoesntSendValueToSinksConnectedLater() {
        let signal = Signal<Int>()

        signal.sendLater(0)
        signal.sendLater(1)
        signal.sendLater(2)

        var r = [Int]()
        let c = signal.connect { r.append($0) }

        signal.sendLater(3)
        signal.sendLater(4)

        XCTAssertEqual(r, [])

        signal.sendNow()

        XCTAssertEqual(r, [3, 4])

        c.disconnect()
    }

    func testSendLaterDoesntSendValueToSinksConnectedLaterEvenIfThereAreOtherSinks() {
        let signal = Signal<Int>()

        var r1 = [Int]()
        let c1 = signal.connect { r1.append($0) }

        signal.sendLater(0)
        signal.sendLater(1)
        signal.sendLater(2)

        var r2 = [Int]()
        let c2 = signal.connect { r2.append($0) }

        signal.sendLater(3)
        signal.sendLater(4)

        XCTAssertEqual(r1, [])
        XCTAssertEqual(r2, [])

        signal.sendNow()

        XCTAssertEqual(r1, [0, 1, 2, 3, 4])
        XCTAssertEqual(r2, [3, 4])

        c1.disconnect()
        c2.disconnect()
    }


    func testSendLaterUsingCounter() {
        var counter = Counter()

        var s = ""
        let c = counter.connect { value in
            s += " (\(value)"
            if value < 5 {
                counter.increment()
            }
            s += ")"
        }

        let v = counter.increment()
        XCTAssertEqual(v, 1)
        XCTAssertEqual(s, " (1) (2) (3) (4) (5)")

        c.disconnect()
    }
}

private struct Counter: SourceType {
    private var lock = Spinlock()
    private var counter: Int = 0
    private var signal = Signal<Int>()

    var source: Source<Int> { return signal.source }

    mutating func increment() -> Int {
        let value: Int = lock.locked {
            let v = ++self.counter
            signal.sendLater(v)
            return v
        }
        signal.sendNow()
        return value
    }
}
