import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
    import MtProtoKitMac
#else
    import Postbox
    import SwiftSignalKit
    import MtProtoKitDynamic
#endif

private final class ManagedCloudChatRemoveMessagesOperationsHelper {
    var operationDisposables: [Int32: Disposable] = [:]
    
    func update(_ entries: [PeerMergedOperationLogEntry]) -> (disposeOperations: [Disposable], beginOperations: [(PeerMergedOperationLogEntry, MetaDisposable)]) {
        var disposeOperations: [Disposable] = []
        var beginOperations: [(PeerMergedOperationLogEntry, MetaDisposable)] = []
        
        var hasRunningOperationForPeerId = Set<PeerId>()
        var validMergedIndices = Set<Int32>()
        for entry in entries {
            if !hasRunningOperationForPeerId.contains(entry.peerId) {
                hasRunningOperationForPeerId.insert(entry.peerId)
                validMergedIndices.insert(entry.mergedIndex)
                
                if self.operationDisposables[entry.mergedIndex] == nil {
                    let disposable = MetaDisposable()
                    beginOperations.append((entry, disposable))
                    self.operationDisposables[entry.mergedIndex] = disposable
                }
            }
        }
        
        var removeMergedIndices: [Int32] = []
        for (mergedIndex, disposable) in self.operationDisposables {
            if !validMergedIndices.contains(mergedIndex) {
                removeMergedIndices.append(mergedIndex)
                disposeOperations.append(disposable)
            }
        }
        
        for mergedIndex in removeMergedIndices {
            self.operationDisposables.removeValue(forKey: mergedIndex)
        }
        
        return (disposeOperations, beginOperations)
    }
    
    func reset() -> [Disposable] {
        let disposables = Array(self.operationDisposables.values)
        self.operationDisposables.removeAll()
        return disposables
    }
}

private func withTakenOperation(postbox: Postbox, peerId: PeerId, tagLocalIndex: Int32, _ f: @escaping (Modifier, PeerMergedOperationLogEntry?) -> Signal<Void, NoError>) -> Signal<Void, NoError> {
    return postbox.modify { modifier -> Signal<Void, NoError> in
        var result: PeerMergedOperationLogEntry?
        modifier.operationLogUpdateEntry(peerId: peerId, tag: OperationLogTags.CloudChatRemoveMessages, tagLocalIndex: tagLocalIndex, { entry in
            if let entry = entry, let _ = entry.mergedIndex, (entry.contents is CloudChatRemoveMessagesOperation || entry.contents is CloudChatRemoveChatOperation)  {
                result = entry.mergedEntry!
                return PeerOperationLogEntryUpdate(mergedIndex: .none, contents: .none)
            } else {
                return PeerOperationLogEntryUpdate(mergedIndex: .none, contents: .none)
            }
        })
        
        return f(modifier, result)
    } |> switchToLatest
}

func managedCloudChatRemoveMessagesOperations(postbox: Postbox, network: Network, stateManager: AccountStateManager) -> Signal<Void, NoError> {
    return Signal { _ in
        let helper = Atomic<ManagedCloudChatRemoveMessagesOperationsHelper>(value: ManagedCloudChatRemoveMessagesOperationsHelper())
        
        let disposable = postbox.mergedOperationLogView(tag: OperationLogTags.CloudChatRemoveMessages, limit: 10).start(next: { view in
            let (disposeOperations, beginOperations) = helper.with { helper -> (disposeOperations: [Disposable], beginOperations: [(PeerMergedOperationLogEntry, MetaDisposable)]) in
                return helper.update(view.entries)
            }
            
            for disposable in disposeOperations {
                disposable.dispose()
            }
            
            for (entry, disposable) in beginOperations {
                let signal = withTakenOperation(postbox: postbox, peerId: entry.peerId, tagLocalIndex: entry.tagLocalIndex, { modifier, entry -> Signal<Void, NoError> in
                    if let entry = entry {
                        if let operation = entry.contents as? CloudChatRemoveMessagesOperation {
                            if let peer = modifier.getPeer(entry.peerId) {
                                return removeMessages(postbox: postbox, network: network, stateManager: stateManager, peer: peer, operation: operation)
                            } else {
                                return .complete()
                            }
                        } else if let operation = entry.contents as? CloudChatRemoveChatOperation {
                            if let peer = modifier.getPeer(entry.peerId) {
                                return removeChat(modifier: modifier, postbox: postbox, network: network, stateManager: stateManager, peer: peer, operation: operation)
                            } else {
                                return .complete()
                            }
                        } else {
                            assertionFailure()
                        }
                    }
                    return .complete()
                })
                |> then(postbox.modify { modifier -> Void in
                    let _ = modifier.operationLogRemoveEntry(peerId: entry.peerId, tag: OperationLogTags.CloudChatRemoveMessages, tagLocalIndex: entry.tagLocalIndex)
                })
                
                disposable.set(signal.start())
            }
        })
        
        return ActionDisposable {
            let disposables = helper.with { helper -> [Disposable] in
                return helper.reset()
            }
            for disposable in disposables {
                disposable.dispose()
            }
            disposable.dispose()
        }
    }
}

private func removeMessages(postbox: Postbox, network: Network, stateManager: AccountStateManager, peer: Peer, operation: CloudChatRemoveMessagesOperation) -> Signal<Void, NoError> {
    if peer.id.namespace == Namespaces.Peer.CloudChannel {
        if let inputChannel = apiInputChannel(peer) {
            return network.request(Api.functions.channels.deleteMessages(channel: inputChannel, id: operation.messageIds.map { $0.id }))
                |> map { result -> Api.messages.AffectedMessages? in
                    return result
                }
                |> `catch` { _ in
                    return .single(nil)
                }
                |> mapToSignal { _ in
                    return .complete()
                }
        } else {
            return .complete()
        }
    } else {
        return network.request(Api.functions.messages.deleteMessages(flags: 0, id: operation.messageIds.map { $0.id }))
            |> map { result -> Api.messages.AffectedMessages? in
                return result
            }
            |> `catch` { _ in
                return .single(nil)
            }
            |> mapToSignal { result in
                if let result = result {
                    switch result {
                        case let .affectedMessages(pts, ptsCount):
                            stateManager.addUpdateGroups([.updatePts(pts: pts, ptsCount: ptsCount)])
                    }
                }
                return .complete()
            }
    }
}

private func removeChat(modifier: Modifier, postbox: Postbox, network: Network, stateManager: AccountStateManager, peer: Peer, operation: CloudChatRemoveChatOperation) -> Signal<Void, NoError> {
    if peer.id.namespace == Namespaces.Peer.CloudChannel {
        if let inputChannel = apiInputChannel(peer) {
            let signal: Signal<Api.Updates, MTRpcError>
            if let channel = peer as? TelegramChannel, case .creator = channel.role {
                signal = network.request(Api.functions.channels.deleteChannel(channel: inputChannel))
            } else {
                signal = network.request(Api.functions.channels.leaveChannel(channel: inputChannel))
            }
            return signal
                |> map { result -> Api.Updates? in
                    return result
                }
                |> `catch` { _ in
                    return .single(nil)
                }
                |> mapToSignal { updates in
                    if let updates = updates {
                        stateManager.addUpdates(updates)
                    }
                    return .complete()
                }
        } else {
            return .complete()
        }
    } else if peer.id.namespace == Namespaces.Peer.CloudGroup {
        let deleteUser: Signal<Void, NoError> = network.request(Api.functions.messages.deleteChatUser(chatId: peer.id.id, userId: Api.InputUser.inputUserSelf))
            |> map { result -> Api.Updates? in
                return result
            }
            |> `catch` { _ in
                return .single(nil)
            }
            |> mapToSignal { updates in
                if let updates = updates {
                    stateManager.addUpdates(updates)
                }
                return .complete()
            }
        let deleteMessages: Signal<Void, NoError>
        if let inputPeer = apiInputPeer(peer), let topMessageId = modifier.getTopPeerMessageId(peerId: peer.id, namespace: Namespaces.Message.Cloud) {
            deleteMessages = network.request(Api.functions.messages.deleteHistory(flags: 0, peer: inputPeer, maxId: topMessageId.id))
                |> map { result -> Api.messages.AffectedHistory? in
                    return result
                }
                |> `catch` { _ in
                    return .single(nil)
                }
                |> mapToSignal { result in
                    if let result = result {
                        switch result {
                        case let .affectedHistory(pts, ptsCount, _):
                            stateManager.addUpdateGroups([.updatePts(pts: pts, ptsCount: ptsCount)])
                        }
                    }
                    return .complete()
                }
        } else {
            deleteMessages = .complete()
        }
        return deleteMessages |> then(deleteUser)
    } else if peer.id.namespace == Namespaces.Peer.CloudUser {
        if let inputPeer = apiInputPeer(peer), let topMessageId = modifier.getTopPeerMessageId(peerId: peer.id, namespace: Namespaces.Message.Cloud) {
            return network.request(Api.functions.messages.deleteHistory(flags: 0, peer: inputPeer, maxId: topMessageId.id))
                |> map { result -> Api.messages.AffectedHistory? in
                    return result
                }
                |> `catch` { _ in
                    return .single(nil)
                }
                |> mapToSignal { result in
                    if let result = result {
                        switch result {
                            case let .affectedHistory(pts, ptsCount, _):
                                stateManager.addUpdateGroups([.updatePts(pts: pts, ptsCount: ptsCount)])
                        }
                    }
                    return .complete()
                }
        } else {
            return .complete()
        }
    } else {
        return .complete()
    }
}