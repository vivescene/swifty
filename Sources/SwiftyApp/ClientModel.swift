import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ClientModel {
    struct Account: Identifiable, Equatable, Sendable {
        let id: String
        let username: String
        let discriminator: String?
        let avatarURL: URL?
    }

    struct Server: Identifiable, Equatable, Sendable {
        let id: String
        let accountID: String
        let name: String
        let initials: String
    }

    struct Channel: Identifiable, Equatable, Sendable {
        let id: String
        let accountID: String
        let serverID: String
        let name: String
        let topic: String?
    }

    struct Message: Identifiable, Equatable, Sendable {
        let id: String
        let accountID: String
        let channelID: String
        let authorName: String
        let body: String
        let timestamp: Date
    }

    private(set) var account: Account?
    private(set) var servers: [Server] = []
    private(set) var channels: [Channel] = []
    private(set) var messages: [Message] = []
    var selectedChannelID: Channel.ID?
    var composerText = ""
    var shouldFocusComposer = false

    var activeServers: [Server] {
        guard let account else { return [] }
        return servers.filter { $0.accountID == account.id }
    }

    var activeChannels: [Channel] {
        guard let account else { return [] }
        return channels.filter { $0.accountID == account.id }
    }

    var selectedChannel: Channel? {
        guard let selectedChannelID, let account else { return nil }
        return channels.first {
            $0.id == selectedChannelID && $0.accountID == account.id
        }
    }

    var selectedServer: Server? {
        guard let serverID = selectedChannel?.serverID else { return nil }
        return activeServers.first { $0.id == serverID }
    }

    /// Starts a new account session and drops the previous session's cached metadata.
    func activateAccount(_ account: Account) {
        if self.account?.id != account.id {
            clearSessionData()
        }
        self.account = account
    }

    /// Ends the active account session and clears all account-scoped UI/cache state.
    func deactivateAccount() {
        clearSessionData()
        account = nil
    }

    /// Publishes data only for the currently authenticated account.
    func setSessionData(
        servers: [Server],
        channels: [Channel],
        messages: [Message],
        for accountID: Account.ID
    ) {
        guard account?.id == accountID else { return }
        self.servers = servers.filter { $0.accountID == accountID }
        self.channels = channels.filter { $0.accountID == accountID }
        self.messages = messages.filter { $0.accountID == accountID }
        if let selectedChannelID, !self.channels.contains(where: { $0.id == selectedChannelID }) {
            self.selectedChannelID = nil
        }
    }

    func focusComposer() {
        shouldFocusComposer = true
    }

    func messages(for channel: Channel) -> [Message] {
        guard let account, channel.accountID == account.id else { return [] }
        return messages.filter { message in
            message.accountID == account.id && message.channelID == channel.id
        }
    }

    func sendComposerMessage() {
        let body = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let account, let selectedChannel else { return }

        messages.append(
            Message(
                id: UUID().uuidString,
                accountID: account.id,
                channelID: selectedChannel.id,
                authorName: account.username,
                body: body,
                timestamp: .now
            )
        )
        composerText = ""
    }

    private func clearSessionData() {
        servers = []
        channels = []
        messages = []
        selectedChannelID = nil
        composerText = ""
        shouldFocusComposer = false
    }
}
