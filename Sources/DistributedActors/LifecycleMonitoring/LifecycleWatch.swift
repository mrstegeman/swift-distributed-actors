//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import _Distributed
import Dispatch
import NIO

/// Provides a distributed actor with the ability to "watch" other actors lifecycles.
///
/// - Warning: This protocol can only be adopted by DistributedActors, and will gain `where Self: DistributedActor' however a compiler limitation currently prevents us from doing that
public protocol LifecycleWatch {
    // FIXME(distributed): we can't express the Self: Distributed actor, because the runtime does not understand "hop to distributed actor" - rdar://84054772
    // public protocol LifecycleWatch where Self: DistributedActor {

    nonisolated var actorTransport: ActorTransport { get } // FIXME: replace with DistributedActor conformance
    nonisolated var id: AnyActorIdentity { get } // FIXME: replace with DistributedActor conformance
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Lifecycle Watch API

extension LifecycleWatch {
    @discardableResult
    public func watchTermination<Watchee>(
        of watchee: Watchee,
        @_inheritActorContext @_implicitSelfCapture whenTerminated: @escaping @Sendable(AnyActorIdentity) -> Void,
        file: String = #file, line: UInt = #line
    ) -> Watchee where Self: DistributedActor, Watchee: DistributedActor { // TODO(distributed): allow only Watchee where the watched actor is on a transport that supports watching
        // TODO(distributed): reimplement this as self.id as? _ActorContext which will have the watch things.
        guard let system = self.actorTransport._unwrapActorSystem else {
            fatalError("TODO: handle more gracefully") // TODO: handle more gracefully, i.e. say that we can't watch that actor
        }

        guard let watch = system._getLifecycleWatch(watcher: self) else {
            return watchee
        }

        watch.termination(of: watchee, whenTerminated: whenTerminated, file: file, line: line)
        return watchee
    }

    /// Reverts the watching of an previously watched actor.
    ///
    /// Unwatching a not-previously-watched actor has no effect.
    ///
    /// ### Semantics for in-flight Terminated signals
    ///
    /// After invoking `unwatch`, even if a `Signals.Terminated` signal was already enqueued at this actors
    /// mailbox; this signal would NOT be delivered, since the intent of no longer watching the terminating
    /// actor takes immediate effect.
    ///
    /// #### Concurrency:
    ///  - MUST NOT be invoked concurrently to the actors execution, i.e. from the "outside" of the current actor.
    ///
    /// - Returns: the passed in watchee reference for easy chaining `e.g. return context.unwatch(ref)`
    public func isWatching<Watchee>(_ watchee: Watchee) -> Bool where Self: DistributedActor, Watchee: DistributedActor {
        // TODO(distributed): reimplement this as self.id as? _ActorContext which will have the watch things.
        guard let system = self.actorTransport._unwrapActorSystem else {
            fatalError("TODO: handle more gracefully") // TODO: handle more gracefully, i.e. say that we can't watch that actor
        }

        return system._getLifecycleWatch(watcher: self)?.isWatching(watchee.id) ?? false
    }

    /// Reverts the watching of an previously watched actor.
    ///
    /// Unwatching a not-previously-watched actor has no effect.
    ///
    /// ### Semantics for in-flight Terminated signals
    ///
    /// After invoking `unwatch`, even if a `Signals.Terminated` signal was already enqueued at this actors
    /// mailbox; this signal would NOT be delivered to the `onSignal` behavior, since the intent of no longer
    /// watching the terminating actor takes immediate effect.
    ///
    /// #### Concurrency:
    ///  - MUST NOT be invoked concurrently to the actors execution, i.e. from the "outside" of the current actor.
    ///
    /// - Returns: the passed in watchee reference for easy chaining `e.g. return context.unwatch(ref)`
    @discardableResult
    public func unwatch<Watchee>(
        _ watchee: Watchee,
        file: String = #file, line: UInt = #line
    ) -> Watchee where Self: DistributedActor, Watchee: DistributedActor {
        // TODO(distributed): reimplement this as self.id as? _ActorContext which will have the watch things.
        guard let system = self.actorTransport._unwrapActorSystem else {
            fatalError("Can't \(#function) \(watchee) @ (\(watchee.id)), does not seem to be managed by ActorSystem") // TODO: handle more gracefully, i.e. say that we can't watch that actor
        }

        guard let watch = system._getLifecycleWatch(watcher: self) else {
            return watchee
        }

        return watch.unwatch(watchee: watchee, file: file, line: line)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: "Internal" functions made to make the watch signals work

extension LifecycleWatch {
    /// Function invoked by the actor transport when a distributed termination is detected.
    public func _receiveActorTerminated(identity: AnyActorIdentity) async throws where Self: DistributedActor {
        guard let system = self.actorTransport._unwrapActorSystem else {
            return // TODO: error instead
        }

        guard let watch: LifecycleWatchContainer = system._getLifecycleWatch(watcher: self) else {
            return
        }

        watch.receiveTerminated(identity)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: System extensions to support watching // TODO: move those into context, and make the ActorIdentity the context

extension ActorSystem {
    public func _makeLifecycleWatch<Watcher: LifecycleWatch & DistributedActor>(watcher: Watcher) -> LifecycleWatchContainer {
        return self.lifecycleWatchLock.withLock {
            if let watch = self._lifecycleWatches[watcher.id] {
                return watch
            }

            let watch = LifecycleWatchContainer(watcher)
            self._lifecycleWatches[watcher.id] = watch
            return watch
        }
    }

    // public func _getWatch<DA: DistributedActor>(_ actor: DA) -> LifecycleWatchContainer? {
    public func _getLifecycleWatch<Watcher: LifecycleWatch & DistributedActor>(watcher: Watcher) -> LifecycleWatchContainer? {
        return self.lifecycleWatchLock.withLock {
            return self._lifecycleWatches[watcher.id]
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: LifecycleWatchContainer

/// Implements watching distributed actors for termination.
///
/// Termination of local actors is simply whenever they deinitialize.
/// Remote actors are considered terminated when they deinitialize, same as local actors,
/// or when the node hosting them is declared `.down`.
public final class LifecycleWatchContainer {
    private weak var myself: DistributedActor? // TODO: make this just store the address instead?
    private let myselfID: AnyActorIdentity

    private let system: ActorSystem
    private let nodeDeathWatcher: NodeDeathWatcherShell.Ref?

    typealias OnTerminatedFn = @Sendable(AnyActorIdentity) async -> Void
    private var watching: [AnyActorIdentity: OnTerminatedFn] = [:]
    private var watchedBy: [AnyActorIdentity: AddressableActorRef] = [:]

    // FIXME(distributed): use the Transport typealias to restrict that the transport has watch support
    init<Act>(_ myself: Act) where Act: DistributedActor {
        traceLog_DeathWatch("Make LifecycleWatchContainer owned by \(myself.id)")
        self.myself = myself
        self.myselfID = myself.id
        let system = myself.actorTransport._forceUnwrapActorSystem
        self.system = system
        self.nodeDeathWatcher = system._nodeDeathWatcher
    }

    deinit {
        traceLog_DeathWatch("Deinit LifecycleWatchContainer owned by \(myselfID)")
        for watched in watching.values {
            nodeDeathWatcher?.tell(.removeWatcher(watcherIdentity: myselfID))
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: perform watch/unwatch

extension LifecycleWatchContainer {
    /// Performed by the sending side of "watch", therefore the `watcher` should equal `context.myself`
    public func termination<Watchee>(
        of watchee: Watchee,
        @_inheritActorContext @_implicitSelfCapture whenTerminated: @escaping @Sendable(AnyActorIdentity) -> Void,
        file: String = #file, line: UInt = #line
    ) where // Watchee: _DeathWatchable,
        Watchee: DistributedActor {
        traceLog_DeathWatch("issue watch: \(watchee) (from \(optional: self.myself))")

        guard let watcheeAddress = watchee.id._unwrapActorAddress else {
            fatalError("Cannot watch actor \(watchee), it is not managed by the cluster. Identity: \(watchee.id.underlying)")
        }

        guard let watcherAddress = myself?.id._unwrapActorAddress else {
            fatalError("Cannot watch from actor \(optional: self.myself), it is not managed by the cluster. Identity: \(watchee.id.underlying)")
        }

        // watching ourselves is a no-op, since we would never be able to observe the Terminated message anyway:
        guard watcheeAddress != watcherAddress else {
            return
        }

        let addressableWatchee = self.system._resolveUntyped(context: .init(address: watcheeAddress, system: self.system))
        let addressableWatcher = self.system._resolveUntyped(context: .init(address: watcherAddress, system: self.system))

        if self.isWatching(watchee.id) {
            // While we bail out early here, we DO override whichever value was set as the customized termination message.
            // This is to enable being able to keep updating the context associated with a watched actor, e.g. if how
            // we should react to its termination has changed since the last time watch() was invoked.
            self.watching[watchee.id] = whenTerminated

            return
        } else {
            // not yet watching, so let's add it:
            self.watching[watchee.id] = whenTerminated

            addressableWatchee._sendSystemMessage(.watch(watchee: addressableWatchee, watcher: addressableWatcher), file: file, line: line)
            self.subscribeNodeTerminatedEvents(watchedAddress: watcheeAddress, file: file, line: line)
        }
    }

    /// Reverts the watching of an previously watched actor.
    ///
    /// Unwatching a not-previously-watched actor has no effect.
    ///
    /// ### Semantics for in-flight Terminated signals
    ///
    /// After invoking `unwatch`, even if a `Signals.Terminated` signal was already enqueued at this actors
    /// mailbox; this signal would NOT be delivered to the `onSignal` behavior, since the intent of no longer
    /// watching the terminating actor takes immediate effect.
    ///
    /// #### Concurrency:
    ///  - MUST NOT be invoked concurrently to the actors execution, i.e. from the "outside" of the current actor.
    ///
    /// - Returns: the passed in watchee reference for easy chaining `e.g. return context.unwatch(ref)`
    public func unwatch<Watchee>(
        watchee: Watchee,
        file: String = #file, line: UInt = #line
    ) -> Watchee where Watchee: DistributedActor {
        traceLog_DeathWatch("issue unwatch: watchee: \(watchee) (from \(optional: self.myself))")
        guard let watcheeAddress = watchee.id._unwrapActorAddress else {
            return watchee
        }
        guard let watcherAddress = myself?.id._unwrapActorAddress else {
            return watchee
        }

        // FIXME(distributed): we have to make this nicer, the ID itself must "be" the ref
        let system = watchee.actorTransport._forceUnwrapActorSystem
        let addressableWatchee = system._resolveUntyped(context: .init(address: watcheeAddress, system: system))
        let addressableMyself = system._resolveUntyped(context: .init(address: watcherAddress, system: system))

        // we could short circuit "if watchee == myself return" but it's not really worth checking since no-op anyway
        if self.watching.removeValue(forKey: watchee.id) != nil {
            addressableWatchee._sendSystemMessage(
                .unwatch(
                    watchee: addressableWatchee, watcher: addressableMyself
                ),
                file: file, line: line
            )
        }

        return watchee
    }

    /// - Returns `true` if the passed in actor ref is being watched
    @usableFromInline
    internal func isWatching(_ identity: AnyActorIdentity) -> Bool {
        self.watching[identity] != nil
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: react to watch or unwatch signals

    public func becomeWatchedBy(
        watcher: AddressableActorRef
    ) {
        guard watcher.address != self.myself?.id._unwrapActorAddress else {
            traceLog_DeathWatch("Attempted to watch 'myself' [\(optional: self.myself)], which is a no-op, since such watch's terminated can never be observed. " +
                "Likely a programming error where the wrong actor ref was passed to watch(), please check your code.")
            return
        }

        traceLog_DeathWatch("Become watched by: \(watcher.address)     inside: \(optional: self.myself)")
        self.watchedBy[watcher.address.asAnyActorIdentity] = watcher
    }

    func removeWatchedBy(watcher: AddressableActorRef) {
        traceLog_DeathWatch("Remove watched by: \(watcher.address)     inside: \(optional: self.myself)")
        self.watchedBy.removeValue(forKey: watcher.address.asAnyActorIdentity)
    }

    /// Performs cleanup of references to the dead actor.
    public func receiveTerminated(_ terminated: Signals.Terminated) {
        self.receiveTerminated(terminated.address.asAnyActorIdentity)
    }

    public func receiveTerminated(_ terminatedIdentity: AnyActorIdentity) {
        // we remove the actor from both sets;
        // 1) we don't need to watch it anymore, since it has just terminated,
        let removedOnTerminationFn = self.watching.removeValue(forKey: terminatedIdentity)
        // 2) we don't need to refer to it, since sending it .terminated notifications would be pointless.
        _ = self.watchedBy.removeValue(forKey: terminatedIdentity)

        guard let onTermination = removedOnTerminationFn else {
            // if we had no stored/removed termination message, it means this actor was NOT watched actually.
            // Meaning: don't deliver Signal/message to user actor.
            return
        }

        Task {
            // TODO(distributed): we should surface the additional information (node terminated, existence confirmed) too
            await onTermination(terminatedIdentity)
        }
    }

    /// Performs cleanup of any actor references that were located on the now terminated node.
    ///
    /// Causes `Terminated` signals to be triggered for any such watched remote actor.
    ///
    /// Does NOT immediately handle these `Terminated` signals, they are treated as any other normal signal would,
    /// such that the user can have a chance to handle and react to them.
    public func receiveNodeTerminated(_ terminatedNode: UniqueNode) {
        // TODO: remove actors as we notify about them
        for (watched, _) in self.watching {
            guard let watchedAddress = watched._unwrapActorAddress, watchedAddress.uniqueNode == terminatedNode else {
                continue
            }

            // we KNOW an actor existed if it is local and not resolved as /dead; otherwise it may have existed
            // for a remote ref we don't know for sure if it existed
            // let existenceConfirmed = watched.refType.isLocal && !watched.address.path.starts(with: ._dead)
            let existenceConfirmed = true // TODO: implement support for existence confirmed or drop it?

            guard let address = self.myself?.id._unwrapActorAddress else {
                return
            }

//            let ref = system._resolveUntyped(context: .init(address: address, system: system))
//            ref._sendSystemMessage(.terminated(ref: watched, existenceConfirmed: existenceConfirmed, addressTerminated: true), file: #file, line: #line)
            // fn(watched)
            self.receiveTerminated(watched)
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Myself termination

    func notifyWatchersWeDied() {
        traceLog_DeathWatch("[\(optional: self.myself)] notifyWatchers that we are terminating. Watchers: \(self.watchedBy)...")

        for (watcherIdentity, watcherRef) in self.watchedBy {
            traceLog_DeathWatch("[\(optional: self.myself)] Notify  \(watcherIdentity) (\(watcherRef)) that we died")
            if let address = myself?.id._unwrapActorAddress {
                let fakeRef = _ActorRef<_Done>(.deadLetters(.init(.init(label: "x"), address: address, system: nil)))
                watcherRef._sendSystemMessage(.terminated(ref: fakeRef.asAddressable, existenceConfirmed: true))
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Node termination

    private func subscribeNodeTerminatedEvents(
        watchedAddress: ActorAddress,
        file: String = #file, line: UInt = #line
    ) {
        guard let id = myself?.id else {
            return
        }

        self.nodeDeathWatcher?.tell( // different actor
            .remoteDistributedActorWatched(
                remoteNode: watchedAddress.uniqueNode,
                watcherIdentity: id,
                nodeTerminated: { [weak system] uniqueNode in
                    guard let myselfRef = system?._resolveUntyped(context: .init(address: id._forceUnwrapActorAddress, system: system!)) else {
                        return
                    }
                    myselfRef._sendSystemMessage(.nodeTerminated(uniqueNode), file: file, line: line)
                }
            )
        )
    }
}
