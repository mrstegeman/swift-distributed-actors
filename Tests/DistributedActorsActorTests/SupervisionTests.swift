//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import XCTest
import NIO
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

class SupervisionTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(system)
    }

    override func tearDown() {
        self.system.shutdown()
    }
    enum FaultyError: Error {
        case boom(message: String)
    }
    enum FaultyMessage {
        case pleaseThrow(error: Error)
        case pleaseFatalError(message: String)
        case pleaseDivideByZero
        case echo(message: String, replyTo: ActorRef<WorkerMessages>)
    }

    enum SimpleProbeMessages: Equatable {
        case spawned(child: ActorRef<FaultyMessage>)
        case echoing(message: String)
    }

    enum WorkerMessages: Equatable {
        case setupRunning(ref: ActorRef<FaultyMessage>)
        case echo(message: String)
    }

    enum FailureMode {
        case throwing
        case faulting

        func fail() throws {
            switch self {
            case .faulting: fatalError("SIGNAL_BOOM")
            case .throwing: throw FaultyError.boom(message: "SIGNAL_BOOM")
            }
        }
    }

    func faulty(probe: ActorRef<WorkerMessages>?) -> Behavior<FaultyMessage> {
        return .setup { context in
            probe?.tell(.setupRunning(ref: context.myself))

            return .receiveMessage {
                switch $0 {
                case .pleaseThrow(let error):
                    throw error
                case .pleaseFatalError(let msg):
                    fatalError(msg)
                case .pleaseDivideByZero:
                    let zero = Int("0")! // to trick swiftc into allowing us to write "/ 0", which it otherwise catches at compile time
                    _ = 100 / zero
                    return .same
                case let .echo(msg, sender):
                    sender.tell(.echo(message: "echo:\(msg)"))
                    return .same
                }
            }
        }
    }

    // TODO: test a double fault (throwing inside of a supervisor

    func compileOnlyDSLReadabilityTest() {
        _ = { () -> Void in
            let behavior: Behavior<String> = undefined()
            _ = try self.system.spawn(behavior, name: "example")
            _ = try self.system.spawn(behavior, name: "example", props: Props())
            _ = try self.system.spawn(behavior, name: "example", props: .withDispatcher(.pinnedThread))
            _ = try self.system.spawn(behavior, name: "example", props: Props().withDispatcher(.pinnedThread).addingSupervision(strategy: .stop))
            // nope: _ = try self.system.spawn(behavior, name: "example", props: .withDispatcher(.PinnedThread).addingSupervision(strategy: .stop))
            // /Users/ktoso/code/sact/Tests/Swift Distributed ActorsActorTests/SupervisionTests.swift:120:15: error: expression type '()' is ambiguous without more context
            _ = try self.system.spawn(behavior, name: "example", props: .addingSupervision(strategy: .restart(atMost: 5, within: .seconds(1))))
            _ = try self.system.spawn(behavior, name: "example", props: .addingSupervision(strategy: .restart(atMost: 5, within: .effectivelyInfinite)))

            // chaining
            _ = try self.system.spawn(behavior, name: "example",
                props: Props()
                    .addingSupervision(strategy: .restart(atMost: 5, within: .effectivelyInfinite))
                    .withDispatcher(.pinnedThread)
                    .withMailbox(.default(capacity: 122, onOverflow: .crash))
            )

            _ = try self.system.spawn(behavior, name: "example",
                props: Props()
                    .addingSupervision(strategy: .restart(atMost: 5, within: .seconds(1)), forErrorType: EasilyCatchable.self)
                    .addingSupervision(strategy: .restart(atMost: 5, within: .effectivelyInfinite))
                    .addingSupervision(strategy: .restart(atMost: 5, within: .effectivelyInfinite))
            )
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Shared test implementation, which is to run with either error/fault causing messages

    func sharedTestLogic_isolatedFailureHandling_shouldStopActorOnFailure(runName: String, makeEvilMessage: (String) -> FaultyMessage) throws {
        let p = testKit.spawnTestProbe(expecting: WorkerMessages.self)
        let pp = testKit.spawnTestProbe(expecting: Never.self)


        let parentBehavior: Behavior<Never> = .setup { context in
            let strategy: SupervisionStrategy = .stop
            let behavior = self.faulty(probe: p.ref)
            let _: ActorRef<FaultyMessage> = try context.spawn(behavior, name: "\(runName)-erroring-1", 
                props: .addingSupervision(strategy: strategy))
            return .same
        }
        let interceptedParent = pp.interceptAllMessages(sentTo: parentBehavior) // TODO intercept not needed

        let parent: ActorRef<Never> = try system.spawn(interceptedParent, name: "\(runName)-parent")

        guard case let .setupRunning(faultyWorker) = try p.expectMessage() else { throw p.error() }

        p.watch(faultyWorker)
        faultyWorker.tell(makeEvilMessage("Boom"))

        // it should have stopped on the failure
        try p.expectTerminated(faultyWorker)

        // meaning that the .stop did not accidentally also cause the parent to die
        // after all, it dod NOT watch the faulty actor, so death pact also does not come into play
        pp.watch(parent)
        try pp.expectNoTerminationSignal(for: .milliseconds(100))

    }

    func sharedTestLogic_restartSupervised_shouldRestart(runName: String, makeEvilMessage: (String) -> FaultyMessage) throws {
        let p = testKit.spawnTestProbe(expecting: WorkerMessages.self)
        let pp = testKit.spawnTestProbe(expecting: Never.self)


        let parentBehavior: Behavior<Never> = .setup { context in
            let _: ActorRef<FaultyMessage> = try context.spawn(
                self.faulty(probe: p.ref),
                name: "\(runName)-erroring-2", 
                props: Props().addingSupervision(strategy: .restart(atMost: 2, within: .seconds(1))))

            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior)

        let parent: ActorRef<Never> = try system.spawn(behavior, name: "\(runName)-parent-2")
        pp.watch(parent)

        guard case let .setupRunning(faultyWorker) = try p.expectMessage() else { throw p.error() }
        p.watch(faultyWorker)

        faultyWorker.tell(.echo(message: "one", replyTo: p.ref))
        try p.expectMessage(WorkerMessages.echo(message: "echo:one"))

        faultyWorker.tell(makeEvilMessage("Boom: 1st (\(runName))"))
        try p.expectNoTerminationSignal(for: .milliseconds(300)) // faulty worker did not terminate, it restarted
        try pp.expectNoTerminationSignal(for: .milliseconds(100)) // parent did not terminate

        pinfo("Now expecting it to run setup again...")
        guard case let .setupRunning(faultyWorkerRestarted) = try p.expectMessage() else { throw p.error() }

        // the `myself` ref of a restarted ref should be EXACTLY the same as the original one, the actor identity remains the same
        faultyWorkerRestarted.shouldEqual(faultyWorker)

        pinfo("Not expecting a reply from it")
        faultyWorker.tell(.echo(message: "two", replyTo: p.ref))
        try p.expectMessage(WorkerMessages.echo(message: "echo:two"))


        faultyWorker.tell(makeEvilMessage("Boom: 2nd (\(runName))"))
        try p.expectNoTerminationSignal(for: .milliseconds(300))

        pinfo("Now it boomed but did not crash again!")
    }

    func sharedTestLogic_restartSupervised_shouldRestartWithConstantBackoff(
            runName: String,
            makeEvilMessage: @escaping (String) -> FaultyMessage) throws {
        let backoff = Backoff.constant(.milliseconds(200))

        let p = testKit.spawnTestProbe(expecting: WorkerMessages.self)
        let pp = testKit.spawnTestProbe(expecting: Never.self)


        let parentBehavior: Behavior<Never> = .setup { context in
            let _: ActorRef<FaultyMessage> = try context.spawn(
                self.faulty(probe: p.ref), name: "\(runName)-failing-2", 
                props: Props().addingSupervision(strategy: .restart(atMost: 3, within: .seconds(1), backoff: backoff)))

            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior)

        let parent: ActorRef<Never> = try system.spawn(behavior, name: "\(runName)-parent-2")
        pp.watch(parent)

        guard case let .setupRunning(faultyWorker) = try p.expectMessage() else { throw p.error() }
        p.watch(faultyWorker)

        func boomExpectBackoffRestart(expectedBackoff: Swift Distributed ActorsActor.TimeAmount) throws {
            // confirm it is alive and working
            faultyWorker.tell(.echo(message: "one", replyTo: p.ref))
            try p.expectMessage(WorkerMessages.echo(message: "echo:one"))

            pinfo("make it crash")
            // make it crash
            faultyWorker.tell(makeEvilMessage("Boom: (\(runName))"))

            // TODO: these tests would be much nicer if we had a controllable clock
            // the racy part is: if we wait for exactly the amount of time of the backoff,
            // we may be waiting "slightly too long" and get the unexpected message;
            // we currently work around this by waiting slightly less.

            pinfo("expect no restart for \(expectedBackoff)")
            let expectedSlightlyShortedToAvoidRaces = expectedBackoff - .milliseconds(50)
            try p.expectNoMessage(for: expectedSlightlyShortedToAvoidRaces)

            // it should finally restart though
            guard case let .setupRunning(faultyWorkerRestarted) = try p.expectMessage() else { throw p.error() }
            pinfo("restarted!")

            // the `myself` ref of a restarted ref should be EXACTLY the same as the original one, the actor identity remains the same
            faultyWorkerRestarted.shouldEqual(faultyWorker)
        }

        try boomExpectBackoffRestart(expectedBackoff: backoff.timeAmount)
        try boomExpectBackoffRestart(expectedBackoff: backoff.timeAmount)
        try boomExpectBackoffRestart(expectedBackoff: backoff.timeAmount)
    }

    func sharedTestLogic_restartSupervised_shouldRestartWithExponentialBackoff(
            runName: String,
            makeEvilMessage: @escaping (String) -> FaultyMessage) throws {
        let initialInterval: Swift Distributed ActorsActor.TimeAmount = .milliseconds(100)
        let multiplier = 2.0
        let backoff = Backoff.exponential(
            initialInterval: initialInterval,
            multiplier: multiplier,
            randomFactor: 0.0
        )

        let p = testKit.spawnTestProbe(expecting: WorkerMessages.self)
        let pp = testKit.spawnTestProbe(expecting: Never.self)

        let parentBehavior: Behavior<Never> = .setup { context in
            let _: ActorRef<FaultyMessage> = try context.spawn(
                self.faulty(probe: p.ref), name: "\(runName)-exponentialBackingOff", 
                props: Props().addingSupervision(strategy: .restart(atMost: 10, within: nil, backoff: backoff)))

            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior)

        let parent: ActorRef<Never> = try system.spawn(behavior, name: "\(runName)-parent-2")
        pp.watch(parent)

        guard case let .setupRunning(faultyWorker) = try p.expectMessage() else { throw p.error() }
        p.watch(faultyWorker)

        func boomExpectBackoffRestart(expectedBackoff: Swift Distributed ActorsActor.TimeAmount) throws {
            // confirm it is alive and working
            faultyWorker.tell(.echo(message: "one", replyTo: p.ref))
            try p.expectMessage(WorkerMessages.echo(message: "echo:one"))

            pinfo("make it crash")
            // make it crash
            faultyWorker.tell(makeEvilMessage("Boom: (\(runName))"))

            // TODO: these tests would be much nicer if we had a controllable clock
            // the racy part is: if we wait for exactly the amount of time of the backoff,
            // we may be waiting "slightly too long" and get the unexpected message;
            // we currently work around this by waiting slightly less.

            pinfo("expect no restart for \(expectedBackoff)")
            let expectedSlightlyShortedToAvoidRaces = expectedBackoff - .milliseconds(50)
            try p.expectNoMessage(for: expectedSlightlyShortedToAvoidRaces)

            // it should finally restart though
            guard case let .setupRunning(faultyWorkerRestarted) = try p.expectMessage() else { throw p.error() }
            pinfo("restarted!")

            // the `myself` ref of a restarted ref should be EXACTLY the same as the original one, the actor identity remains the same
            faultyWorkerRestarted.shouldEqual(faultyWorker)
        }

        try boomExpectBackoffRestart(expectedBackoff: .milliseconds(100))
        try boomExpectBackoffRestart(expectedBackoff: .milliseconds(200))
        try boomExpectBackoffRestart(expectedBackoff: .milliseconds(400))
    }

    func sharedTestLogic_restartAtMostWithin_throws_shouldRestartNoMoreThanAllowedWithinPeriod(runName: String, makeEvilMessage: (String) -> FaultyMessage) throws {
        let p = testKit.spawnTestProbe(expecting: WorkerMessages.self)
        let pp = testKit.spawnTestProbe(expecting: Never.self)

        let failurePeriod: Swift Distributed ActorsActor.TimeAmount = .seconds(1) // .milliseconds(300)

        let parentBehavior: Behavior<Never> = .setup { context in
            let _: ActorRef<FaultyMessage> = try context.spawn(self.faulty(probe: p.ref), name: "\(runName)-erroring-within-2",
                props: .addingSupervision(strategy: .restart(atMost: 2, within: failurePeriod)))
            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior)

        let parent: ActorRef<Never> = try system.spawn(behavior, name: "\(runName)-parent-2")
        pp.watch(parent)

        guard case let .setupRunning(faultyWorker) = try p.expectMessage() else { throw p.error() }
        p.watch(faultyWorker)

        faultyWorker.tell(.echo(message: "one", replyTo: p.ref))
        try p.expectMessage(WorkerMessages.echo(message: "echo:one"))

        pinfo("1st boom...")
        faultyWorker.tell(makeEvilMessage("Boom: 1st (\(runName))"))
        try p.expectNoTerminationSignal(for: .milliseconds(30)) // faulty worker did not terminate, it restarted
        try pp.expectNoTerminationSignal(for: .milliseconds(10)) // parent did not terminate
        guard case .setupRunning = try p.expectMessage() else { throw p.error() }

        pinfo("\(Date()) :: Giving enough breathing time to replenish the restart period (\(failurePeriod))")
        Thread.sleep(failurePeriod)
        pinfo("\(Date()) :: Done sleeping...")

        pinfo("2nd boom...")
        faultyWorker.tell(makeEvilMessage("Boom: 2nd period, 1st failure in period (2nd total) (\(runName))"))
        try p.expectNoTerminationSignal(for: .milliseconds(30)) // faulty worker did not terminate, it restarted
        try pp.expectNoTerminationSignal(for: .milliseconds(10)) // parent did not terminate
        guard case .setupRunning = try p.expectMessage() else { throw p.error() }

        pinfo("3rd boom...")
        // cause another failure right away -- meaning in this period we are up to 2/2 failures
        faultyWorker.tell(makeEvilMessage("Boom: 2nd period, 2nd failure in period (3rd total) (\(runName))"))
        try p.expectNoTerminationSignal(for: .milliseconds(30)) // faulty worker did not terminate, it restarted
        try pp.expectNoTerminationSignal(for: .milliseconds(10)) // parent did not terminate

        pinfo("4th boom...")
        faultyWorker.tell(makeEvilMessage("Boom: 2nd period, 3rd failure in period (4th total) (\(runName))"))
        try p.expectTerminated(faultyWorker)
        try pp.expectNoTerminationSignal(for: .milliseconds(10)) // parent did not terminate
        guard case .setupRunning = try p.expectMessage() else { throw p.error() }

        pinfo("Now it boomed but did not crash again!")
    }

    func sharedTestLogic_restart_shouldHandleFailureWhenInterpretingStart(failureMode: FailureMode) throws {
        let probe = testKit.spawnTestProbe(expecting: String.self)

        let strategy: SupervisionStrategy = .restart(atMost: 5, within: .seconds(10))
        var shouldFail = true
        let behavior: Behavior<String> = .setup { _ in
            if shouldFail {
                shouldFail = false // we only fail the first time
                probe.tell("failing")
                try failureMode.fail()
            }

            probe.tell("starting")

            return .receiveMessage {
                probe.tell("started:\($0)")
                return .same
            }
        }

        let ref: ActorRef<String> = try system.spawn(behavior, name: "fail-in-start-1", props: .addingSupervision(strategy: strategy))

        try probe.expectMessage("failing")
        try probe.expectMessage("starting")
        ref.tell("test")
        try probe.expectMessage("started:test")
    }

    func sharedTestLogic_restart_shouldHandleFailureWhenInterpretingStartAfterFailure(failureMode: FailureMode) throws {
        let probe = testKit.spawnTestProbe(expecting: String.self)

        let strategy: SupervisionStrategy = .restart(atMost: 5, within: .seconds(10))
        // initial setup should not fail
        var shouldFail = false
        let behavior: Behavior<String> = .setup { _ in
            if shouldFail {
                shouldFail = false
                probe.tell("setup:failing")
                try failureMode.fail()
            }

            shouldFail = true // next setup should fail

            probe.tell("starting")

            return .receiveMessage { message in
                switch message {
                case "boom": throw FaultyError.boom(message: "boom")
                default:
                    probe.tell("started:\(message)")
                    return .same
                }
            }
        }

        let ref: ActorRef<String> = try system.spawn(behavior, name: "fail-in-start-2", props: .addingSupervision(strategy: strategy))

        try probe.expectMessage("starting")
        ref.tell("test")
        try probe.expectMessage("started:test")
        ref.tell("boom")
        try probe.expectMessage("setup:failing")
        try probe.expectMessage("starting")
        ref.tell("test")
        try probe.expectMessage("started:test")
    }

    func sharedTestLogic_restart_shouldFailAfterMaxFailuresInSetup(failureMode: FailureMode) throws {
        let probe = testKit.spawnTestProbe(expecting: String.self)

        let strategy: SupervisionStrategy = .restart(atMost: 5, within: .seconds(10))
        let behavior: Behavior<String> = .setup { _ in
            probe.tell("starting")
            try failureMode.fail()
            return .receiveMessage {
                probe.tell("started:\($0)")
                return .same
            }
        }

        let ref: ActorRef<String> = try system.spawn(behavior, name: "fail-in-start-3", props: .addingSupervision(strategy: strategy))
        probe.watch(ref)
        for _ in 1...5 {
            try probe.expectMessage("starting")
        }
        try probe.expectTerminated(ref)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Stopping supervision

    func test_stopSupervised_throws_shouldStop() throws {
        try self.sharedTestLogic_isolatedFailureHandling_shouldStopActorOnFailure(runName: "throws", makeEvilMessage: { msg in
            FaultyMessage.pleaseThrow(error: FaultyError.boom(message: msg))
        })
    }

    func test_stopSupervised_fatalError_shouldStop() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_restartSupervised_shouldRestart(runName: "fatalError", makeEvilMessage: { msg in
            FaultyMessage.pleaseFatalError(message: msg)
        })
        #endif
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Restarting supervision

    func test_restartSupervised_fatalError_shouldRestart() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_restartSupervised_shouldRestart(runName: "fatalError", makeEvilMessage: { msg in
            FaultyMessage.pleaseFatalError(message: msg)
        })
        #endif
    }
    func test_restartSupervised_throws_shouldRestart() throws {
        try self.sharedTestLogic_restartSupervised_shouldRestart(runName: "throws", makeEvilMessage: { msg in
            FaultyMessage.pleaseThrow(error: FaultyError.boom(message: msg))
        })
    }

    func test_restartAtMostWithin_throws_shouldRestartNoMoreThanAllowedWithinPeriod() throws {
        try self.sharedTestLogic_restartAtMostWithin_throws_shouldRestartNoMoreThanAllowedWithinPeriod(runName: "throws", makeEvilMessage: { msg in 
            FaultyMessage.pleaseThrow(error: FaultyError.boom(message: msg))
        })
    }
    func test_restartAtMostWithin_fatalError_shouldRestartNoMoreThanAllowedWithinPeriod() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_restartAtMostWithin_throws_shouldRestartNoMoreThanAllowedWithinPeriod(runName: "fatalError", makeEvilMessage: { msg in
            FaultyMessage.pleaseFatalError(message: msg)
        })
        #endif
    }

    func test_restartSupervised_throws_shouldRestart_andCreateNewInstanceOfClassBehavior() throws {
        let p = testKit.spawnTestProbe(expecting: String.self)
        let ref = try system.spawn(.class { MyCrashingClassBehavior(p.ref) },
            name: "class-behavior", 
            props: .addingSupervision(strategy: .restart(atMost: 2, within: nil)))

        ref.tell("one")
        // throws and restarts
        ref.tell("two")

        try p.expectMessage("init")
        let id1 = try p.expectMessage()
        try p.expectMessage("message:one")
        try p.expectMessage("init")
        let id2 = try p.expectMessage()
        try p.expectMessage("message:two")

        id2.shouldNotEqual(id1)
    }
    class MyCrashingClassBehavior: ClassBehavior<String> {
        let probe: ActorRef<String>

        init(_ probe: ActorRef<String>) {
            self.probe = probe
            super.init()
            probe.tell("init")
            probe.tell("\(ObjectIdentifier(self))")
        }

        override func receive(context: ActorContext<String>, message: String) throws -> Behavior<String> {
            probe.tell("message:\(message)")
            throw FaultyError.boom(message: "Booming on purpose, in class behavior!")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Restarting supervision with Backoff

    func test_restartSupervised_fatalError_shouldRestartWithConstantBackoff() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_restartSupervised_shouldRestartWithConstantBackoff(runName: "fatalError", makeEvilMessage: { msg in
            FaultyMessage.pleaseFatalError(message: msg)
        })
        #endif
    }

    func test_restart_throws_shouldHandleFailureWhenInterpretingStart() throws {
        try self.sharedTestLogic_restart_shouldHandleFailureWhenInterpretingStart(failureMode: .throwing)
    }
    func test_restart_fatalError_shouldHandleFailureWhenInterpretingStart() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_restart_shouldHandleFailureWhenInterpretingStart(failureMode: .faulting)
        #endif
    }
    func test_restartSupervised_throws_shouldRestartWithConstantBackoff() throws {
        try self.sharedTestLogic_restartSupervised_shouldRestartWithConstantBackoff(runName: "throws", makeEvilMessage: { msg in
            FaultyMessage.pleaseThrow(error: FaultyError.boom(message: msg))
        })
    }

    func test_restartSupervised_fatalError_shouldRestartWithExponentialBackoff() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_restartSupervised_shouldRestartWithExponentialBackoff(runName: "fatalError", makeEvilMessage: { msg in
            FaultyMessage.pleaseFatalError(message: msg)
        })
        #endif
    }
    func test_restartSupervised_throws_shouldRestartWithExponentialBackoff() throws {
        try self.sharedTestLogic_restartSupervised_shouldRestartWithExponentialBackoff(runName: "throws", makeEvilMessage: { msg in
            FaultyMessage.pleaseThrow(error: FaultyError.boom(message: msg))
        })
    }

    func test_restart_throws_shouldHandleFailureWhenInterpretingStartAfterFailure() throws {
        try self.sharedTestLogic_restart_shouldHandleFailureWhenInterpretingStartAfterFailure(failureMode: .throwing)
    }
    func test_restart_fatalError_shouldHandleFailureWhenInterpretingStartAfterFailure() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_restart_shouldHandleFailureWhenInterpretingStartAfterFailure(failureMode: .faulting)
        #endif
    }

    func test_restart_throws_shouldFailAfterMaxFailuresInSetup() throws {
        try self.sharedTestLogic_restart_shouldFailAfterMaxFailuresInSetup(failureMode: .throwing)
    }
    func test_restart_fatalError_shouldFailAfterMaxFailuresInSetup() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_restart_shouldFailAfterMaxFailuresInSetup(failureMode: .faulting)
        #endif
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handling faults, divide by zero
    // This should effectively be exactly the same as other faults, but we want to make sure, just in case Swift changes this (so we'd notice early)

    func test_stopSupervised_divideByZero_shouldStop() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_restartSupervised_shouldRestart(runName: "fatalError", makeEvilMessage: { msg in
            FaultyMessage.pleaseDivideByZero
        })
        #endif
    }

    func test_restartSupervised_divideByZero_shouldRestart() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_restartSupervised_shouldRestart(runName: "fatalError", makeEvilMessage: { msg in
            FaultyMessage.pleaseDivideByZero
        })
        #endif
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Composite handler tests

    func test_compositeSupervisor_shouldHandleUsingTheRightHandler() throws {
        let probe = testKit.spawnTestProbe(expecting: WorkerMessages.self)

        let faultyWorker = try system.spawn(self.faulty(probe: probe.ref), name: "compositeFailures-1", 
            props: Props()
                .addingSupervision(strategy: .restart(atMost: 1, within: nil), forErrorType: CatchMe.self)
                .addingSupervision(strategy: .restart(atMost: 1, within: nil), forErrorType: EasilyCatchable.self))

        probe.watch(faultyWorker)

        faultyWorker.tell(.pleaseThrow(error: CatchMe()))
        try probe.expectNoTerminationSignal(for: .milliseconds(20))
        faultyWorker.tell(.pleaseThrow(error: EasilyCatchable()))
        try probe.expectNoTerminationSignal(for: .milliseconds(20))
        faultyWorker.tell(.pleaseThrow(error: CantTouchThis()))
        try probe.expectTerminated(faultyWorker)
    }

    func test_compositeSupervisor_shouldFaultHandleUsingTheRightHandler() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        let probe = testKit.spawnTestProbe(expecting: WorkerMessages.self)

        let faultyWorker = try system.spawn(self.faulty(probe: probe.ref), name: "compositeFailures-1", 
            props: Props()
                .addingSupervision(strategy: .restart(atMost: 2, within: nil), forAll: .faults)
                .addingSupervision(strategy: .restart(atMost: 1, within: nil), forErrorType: CatchMe.self) // should not the limit that .faults has
                .addingSupervision(strategy: .restart(atMost: 1, within: nil), forAll: .failures) // matters, but first in chain is .faults with the 3 limit
            )

        probe.watch(faultyWorker)

        faultyWorker.tell(.pleaseDivideByZero)
        try probe.expectNoTerminationSignal(for: .milliseconds(20))
        faultyWorker.tell(.pleaseDivideByZero)
        try probe.expectNoTerminationSignal(for: .milliseconds(20))
        //        faultyWorker.tell(.pleaseThrow(error: CatchMe()))
        //        try probe.expectNoTerminationSignal(for: .milliseconds(20))
        faultyWorker.tell(.pleaseDivideByZero)
        try probe.expectTerminated(faultyWorker)
        #endif
    }

    // TODO: we should nail down and spec harder exact semantics of the failure counting, I'd say we do.
    // I think that IFF we do subclassing checks then it makes sense to only increment the specific supervisor,
    // but since we do NOT do the subclassing let's keep to the "linear scan during which we +1 every encountered one"
    // and when we hit the right one we trigger its logic. In other words the counts are cumulative within the period --
    // regardless which failures they caused...? Then one could argue that we need to always +1 all of them, which also is fair...
    // All in all, TODO and cement the meaning in docs and tests.

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handling faults inside receiveSignal

    func sharedTestLogic_failInSignalHandling_shouldRestart(failBy failureMode: FailureMode) throws {
        let parentProbe = testKit.spawnTestProbe(expecting: String.self)
        let workerProbe = testKit.spawnTestProbe(expecting: WorkerMessages.self)

        // parent spawns a new child for every message it receives, the workerProbe gets the reference so we can crash it then
        let parentBehavior = Behavior<String>.receive { context, msg in
                let faultyBehavior = self.faulty(probe: workerProbe.ref)
                let _ = try context.spawn(faultyBehavior, name: "\(failureMode)-child")

                return .same
            }.receiveSignal { context, signal in
                if let terminated = signal as? Signals.Terminated {
                    parentProbe.tell("terminated:\(terminated.address.name)")
                    try failureMode.fail()
                }
                return .same
            }

        let parentRef: ActorRef<String> = try system.spawn(parentBehavior, name: "parent",
            props: .addingSupervision(strategy: .restart(atMost: 2, within: nil)))
        parentProbe.watch(parentRef)

        parentRef.tell("spawn")
        guard case let .setupRunning(workerRef1) = try workerProbe.expectMessage() else { throw workerProbe.error() }
        workerProbe.watch(workerRef1)
        workerRef1.tell(.pleaseThrow(error: FaultyError.boom(message: "Boom inside worker.")))
        try parentProbe.expectMessage("terminated:\(failureMode)-child")
        try workerProbe.expectTerminated(workerRef1)
        try parentProbe.expectNoTerminationSignal(for: .milliseconds(50))

        pinfo("2nd child crash round")
        parentRef.tell("spawn")
        guard case let .setupRunning(workerRef2) = try workerProbe.expectMessage() else { throw workerProbe.error() }
        workerProbe.watch(workerRef2)
        workerRef2.tell(.pleaseThrow(error: FaultyError.boom(message: "Boom inside worker.")))
        try parentProbe.expectMessage("terminated:\(failureMode)-child")
        try workerProbe.expectTerminated(workerRef2)
        try parentProbe.expectNoTerminationSignal(for: .milliseconds(50))

        pinfo("3rd child crash round, parent restarts exceeded")
        parentRef.tell("spawn")
        guard case let .setupRunning(workerRef3) = try workerProbe.expectMessage() else { throw workerProbe.error() }
        workerProbe.watch(workerRef3)
        workerRef3.tell(.pleaseThrow(error: FaultyError.boom(message: "Boom inside worker.")))
        try parentProbe.expectMessage("terminated:\(failureMode)-child")
        try workerProbe.expectTerminated(workerRef3)
        try parentProbe.expectTerminated(parentRef)
    }

    func test_throwInSignalHandling_shouldRestart() throws {
        try self.sharedTestLogic_failInSignalHandling_shouldRestart(failBy: .throwing)
    }
    func test_faultInSignalHandling_shouldRestart() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_failInSignalHandling_shouldRestart(failBy: .faulting)
        #endif
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Hard crash tests, hidden under flags (since they really crash the application, and SHOULD do so)

    func test_supervise_notSuperviseStackOverflow() throws {
        #if !SACT_TESTS_CRASH
        pnote("Skipping test \(#function); The test exists to confirm that this type of fault remains NOT supervised. See it crash run with `-D SACT_TESTS_CRASH`")
        return ()
        #endif
        _ = "Skipping test \(#function); The test exists to confirm that this type of fault remains NOT supervised. See it crash run with `-D SACT_TESTS_CRASH`"

        let p = testKit.spawnTestProbe(expecting: WorkerMessages.self)
        let pp = testKit.spawnTestProbe(expecting: Never.self)

        let stackOverflowFaulty: Behavior<SupervisionTests.FaultyMessage> = .setup { context in
            p.tell(.setupRunning(ref: context.myself))
            return .receiveMessage { message in
                return self.daDoRunRunRunDaDoRunRun()
            }
        }

        let parentBehavior: Behavior<Never> = .setup { context in
            let _: ActorRef<FaultyMessage> = try context.spawn(stackOverflowFaulty, name: "bad-decision-erroring-2",
                props: .addingSupervision(strategy: .restart(atMost: 3, within: .seconds(5))))
            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior)

        let parent: ActorRef<Never> = try system.spawn(behavior, name: "bad-decision-parent-2")
        pp.watch(parent)

        guard case let .setupRunning(faultyWorker) = try p.expectMessage() else { throw p.error() }
        p.watch(faultyWorker)

        faultyWorker.tell(.echo(message: "one", replyTo: p.ref))
        try p.expectMessage(WorkerMessages.echo(message: "echo:one"))

        faultyWorker.tell(.pleaseThrow(error: FaultyError.boom(message: "Boom: 1st (bad-decision)")))
        try p.expectTerminated(faultyWorker) // faulty worker DID terminate, since the decision was bogus (".same")
        try pp.expectNoTerminationSignal(for: .milliseconds(100)) // parent did not terminate
    }
    func daDoRunRunRun() -> Behavior<SupervisionTests.FaultyMessage> {
        return daDoRunRunRunDaDoRunRun() // mutually recursive to not trigger warnings; cause stack overflow
    }
    func daDoRunRunRunDaDoRunRun() -> Behavior<SupervisionTests.FaultyMessage> {
        return daDoRunRunRun() // mutually recursive to not trigger warnings; cause stack overflow
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Tests for selective failure handlers

    /// Throws all Errors it receives, EXCEPT `PleaseReply` to which it replies to the probe
    private func throwerBehavior(probe: ActorTestProbe<PleaseReply>) -> Behavior<Error> {
        return .receiveMessage { error in
            switch error {
            case let reply as PleaseReply:
                probe.tell(reply)
            case is PleaseFatalError:
                fatalError("Boom! Fatal error on demand.")
            default:
                throw error
            }
            return .same
        }
    }

    func test_supervisor_shouldOnlyHandle_throwsOfSpecifiedErrorType() throws {
        let p = testKit.spawnTestProbe(expecting: PleaseReply.self)

        let supervisedThrower: ActorRef<Error> = try system.spawn(
            self.throwerBehavior(probe: p),
            name: "thrower-1",
            props: .addingSupervision(strategy: .restart(atMost: 10, within: nil), forErrorType: EasilyCatchable.self))

        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(EasilyCatchable()) // will cause restart
        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(CatchMe()) // will NOT be supervised

        supervisedThrower.tell(PleaseReply())
        try p.expectNoMessage(for: .milliseconds(50))

    }
    func test_supervisor_shouldOnlyHandle_anyThrows() throws {
        let p = testKit.spawnTestProbe(expecting: PleaseReply.self)

        let supervisedThrower: ActorRef<Error> = try system.spawn(
            self.throwerBehavior(probe: p),
            name: "thrower-2",
            props: .addingSupervision(strategy: .restart(atMost: 100, within: nil), forAll: .errors))

        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(EasilyCatchable()) // will cause restart
        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(CatchMe()) // will cause restart

        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

    }
    func test_supervisor_shouldOnlyHandle_anyFault() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        let p = testKit.spawnTestProbe(expecting: PleaseReply.self)

        let supervisedThrower: ActorRef<Error> = try system.spawn(
            self.throwerBehavior(probe: p),
            name: "mr-fawlty-1",
            props: .addingSupervision(strategy: .restart(atMost: 100, within: nil), forAll: .faults))

        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(PleaseFatalError()) // will cause restart
        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(CatchMe()) // will NOT cause restart, we only handle faults here (as unusual of a decision this is, yeah)

        supervisedThrower.tell(PleaseReply())
        try p.expectNoMessage(for: .milliseconds(50))
        #endif
    }
    func test_supervisor_shouldOnlyHandle_anyFailure() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        let p = testKit.spawnTestProbe(expecting: PleaseReply.self)

        let supervisedThrower: ActorRef<Error> = try system.spawn(
            self.throwerBehavior(probe: p),
            name: "any-failure-1",
            props: .addingSupervision(strategy: .restart(atMost: 100, within: nil), forAll: .failures))

        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(PleaseFatalError()) // will cause restart

        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())

        supervisedThrower.tell(CatchMe()) // will cause restart

        supervisedThrower.tell(PleaseReply())
        try p.expectMessage(PleaseReply())
        #endif
    }

    func sharedTestLogic_supervisor_shouldCausePreRestartSignalBeforeRestarting(failBy failureMode: FailureMode) throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = Behavior.receiveMessage { _ in
            try failureMode.fail()
            return .same
        }.receiveSignal { _, signal in
            if signal is Signals.PreRestart {
                p.tell("preRestart")
            }
            return .same
        }

        let ref = try system.spawnAnonymous(behavior, props: .addingSupervision(strategy: .restart(atMost: 1, within: .seconds(5))))
        p.watch(ref)

        ref.tell("test")
        try p.expectMessage("preRestart")

        ref.tell("test")
        try p.expectTerminated(ref)
    }
    func test_supervisor_throws_shouldCausePreRestartSignalBeforeRestarting() throws {
        try sharedTestLogic_supervisor_shouldCausePreRestartSignalBeforeRestarting(failBy: .throwing)
    }
    func test_supervisor_fatalError_shouldCausePreRestartSignalBeforeRestarting() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try sharedTestLogic_supervisor_shouldCausePreRestartSignalBeforeRestarting(failBy: .faulting)
        #else
        pinfo("Skipping test, SACT_DISABLE_FAULT_TESTING was set")
        #endif
    }

    func sharedTestLogic_supervisor_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal(failBy failureMode: FailureMode, backoff: BackoffStrategy?) throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        var preRestartCounter = 0

        let failOnBoom: Behavior<String> = Behavior.receiveMessage { message in
            if message == "boom" {
                try failureMode.fail()
            }
            return .same
        }.receiveSignal { context, signal in

            if signal is Signals.PreRestart {
                preRestartCounter += 1
                p.tell("preRestart-\(preRestartCounter)")
                try failureMode.fail()
                p.tell("NEVER")
            }
            return .same
        }

        let ref = try system.spawn(failOnBoom, name: "fail-onside-pre-restart", props: .addingSupervision(strategy: .restart(atMost: 3, within: nil, backoff: backoff)))
        p.watch(ref)

        ref.tell("boom")
        try p.expectMessage("preRestart-1")
        try p.expectMessage("preRestart-2") // keep trying...
        try p.expectMessage("preRestart-3") // last try...

        ref.tell("hello")
        try p.expectNoMessage(for: .milliseconds(100))

        try p.expectTerminated(ref)
    }
    func test_supervisor_throws_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal() throws {
        try sharedTestLogic_supervisor_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal(failBy: .throwing, backoff: nil)
    }
    func test_supervisor_fatalError_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try sharedTestLogic_supervisor_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal(failBy: .faulting, backoff: nil)
        #else
        pinfo("Skipping test, SACT_DISABLE_FAULT_TESTING was set")
        #endif
    }
    func test_supervisor_throws_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal_withBackoff() throws {
        try sharedTestLogic_supervisor_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal(failBy: .throwing, backoff: Backoff.constant(.milliseconds(10)))
    }
    func test_supervisor_fatalError_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal_withBackoff() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try sharedTestLogic_supervisor_shouldFailIrrecoverablyIfFailingToHandle_PreRestartSignal(failBy: .faulting, backoff: Backoff.constant(.milliseconds(10)))
        #else
        pinfo("Skipping test, SACT_DISABLE_FAULT_TESTING was set")
        #endif
    }

    func test_supervisedActor_shouldNotRestartedWhenCrashingInPostStop() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = .receiveMessage { msg in
            p.tell("crashing:\(msg)")
            return .stop { _ in
                throw FaultyError.boom(message: "test")
            }
        }

        let ref = try system.spawnAnonymous(behavior, props: .addingSupervision(strategy: .restart(atMost: 5, within: .seconds(5))))
        p.watch(ref)

        ref.tell("test")

        try p.expectMessage("crashing:test")
        try p.expectTerminated(ref)

        ref.tell("test2")
        try p.expectNoMessage(for: .milliseconds(50))
    }

    func sharedTestLogic_supervisor_shouldRestartWhenFailingInDispatchedClosure(failBy failureMode: FailureMode) throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let behavior: Behavior<String> = .setup { _ in
            p.tell("setup")
            return .receive { context, msg in
                let cb: AsynchronousCallback<String> = context.makeAsynchronousCallback { str in
                    p.tell("crashing:\(str)")
                    try failureMode.fail()
                }

                context.dispatcher.execute {
                    cb.invoke(msg)
                }

                return .same
            }
        }

        let ref = try system.spawnAnonymous(behavior, props: .addingSupervision(strategy: .restart(atMost: 5, within: .seconds(5))))
        p.watch(ref)

        try p.expectMessage("setup")

        ref.tell("test")
        try p.expectMessage("crashing:test")
        try p.expectNoTerminationSignal(for: .milliseconds(50))

        try p.expectMessage("setup")
        ref.tell("test2")
        try p.expectMessage("crashing:test2")
    }

    func test_supervisor_throws_shouldRestartWhenFailingInDispatcheClosure() throws {
        try self.sharedTestLogic_supervisor_shouldRestartWhenFailingInDispatchedClosure(failBy: .throwing)
    }

    func test_supervisor_fatalError_shouldRestartWhenFailingInDispatcheClosure() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_supervisor_shouldRestartWhenFailingInDispatchedClosure(failBy: .faulting)
        #endif
    }

    func sharedTestLogic_supervisor_awaitResult_shouldInvokeSupervisionWhenFailing(failBy failureMode: FailureMode) throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let el = elg.next()
        let promise = el.makePromise(of: Int.self)
        let future = promise.futureResult

        let behavior: Behavior<String> = .setup { context in
            p.tell("starting")
            return .receiveMessage { message in
                switch message {
                case "suspend":
                    return context.awaitResult(of: future, timeout: .milliseconds(100)) { _ in
                        try failureMode.fail()
                        return .same
                    }
                default:
                    p.tell(message)
                    return .same
                }
            }
        }

        let ref = try system.spawnAnonymous(behavior, props: Props.addingSupervision(strategy: .restart(atMost: 1, within: .seconds(1))))

        try p.expectMessage("starting")
        ref.tell("suspend")
        promise.succeed(1)
        try p.expectMessage("starting")
    }

    func test_supervisor_awaitResult_shouldInvokeSupervisionOnThrow() throws {
        try self.sharedTestLogic_supervisor_awaitResult_shouldInvokeSupervisionWhenFailing(failBy: .throwing)
    }

    func test_supervisor_awaitResult_shouldInvokeSupervisionOnFault() throws {
        #if !SACT_DISABLE_FAULT_TESTING
        try self.sharedTestLogic_supervisor_awaitResult_shouldInvokeSupervisionWhenFailing(failBy: .faulting)
        #endif
    }

    func test_supervisor_awaitResultThrowing_shouldInvokeSupervisionOnFailure() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let el = elg.next()
        let promise = el.makePromise(of: Int.self)
        let future = promise.futureResult

        let behavior: Behavior<String> = .setup { context in
            p.tell("starting")
            return .receiveMessage { message in
                switch message {
                case "suspend":
                    return context.awaitResultThrowing(of: future, timeout: .milliseconds(100)) { _ in
                        return .same
                    }
                default:
                    p.tell(message)
                    return .same
                }
            }
        }

        let ref = try system.spawnAnonymous(behavior, props: Props.addingSupervision(strategy: .restart(atMost: 1, within: .seconds(1))))

        try p.expectMessage("starting")
        ref.tell("suspend")
        promise.fail(FaultyError.boom(message: "boom"))
        try p.expectMessage("starting")
    }

    private struct PleaseReply: Error, Equatable {}
    private struct EasilyCatchable: Error, Equatable {}
    private struct CantTouchThis: Error, Equatable {}
    private struct PleaseFatalError: Error, Equatable {}
    private struct CatchMe: Error, Equatable {}

}

