import AppKit
import SwiftUI

struct ClientShell: View {
    @Bindable var model: ClientModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            DetailColumn(model: model)
        }
        .navigationTitle(model.selectedChannel?.name ?? "Discord")
        .tint(.accentColor)
    }
}

private struct Sidebar: View {
    @Bindable var model: ClientModel

    var body: some View {
        List(selection: $model.selectedChannelID) {
            Section("Account") {
                if let account = model.account {
                    AccountRow(account: account)
                } else {
                    AccountEmptyState()
                }
            }

            Section("Servers") {
                if model.activeServers.isEmpty {
                    SidebarEmptyState(
                        title: "No servers yet",
                        systemImage: "building.2",
                        message: "Sign in to load your Discord servers."
                    )
                } else {
                    ForEach(model.activeServers) { server in
                        ServerRow(server: server)
                    }
                }
            }

            Section("Channels") {
                if model.activeChannels.isEmpty {
                    SidebarEmptyState(
                        title: "No channels",
                        systemImage: "number",
                        message: "Channels will appear when a server is selected."
                    )
                } else {
                    ForEach(model.activeChannels) { channel in
                        Label {
                            Text(channel.name)
                        } icon: {
                            Image(systemName: "number")
                        }
                        .tag(channel.id)
                        .accessibilityLabel("Channel \(channel.name)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Discord navigation")
        .safeAreaInset(edge: .bottom) {
            SidebarFooter(model: model)
        }
    }
}

private struct AccountRow: View {
    let account: ClientModel.Account

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.username)
                    .font(.headline)
                if let discriminator = account.discriminator {
                    Text("#\(discriminator)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signed in as \(account.username)")
    }
}

private struct AccountEmptyState: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("No account connected")
                Text("Authentication will be added here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "person.crop.circle.badge.questionmark")
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No account connected. Authentication will be added here.")
    }
}

private struct ServerRow: View {
    let server: ClientModel.Server

    var body: some View {
        Label {
            Text(server.name)
        } icon: {
            Text(server.initials)
                .font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
        }
        .accessibilityLabel("Server \(server.name)")
    }
}

private struct SidebarEmptyState: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}

private struct SidebarFooter: View {
    @Bindable var model: ClientModel

    var body: some View {
        HStack {
            Label("Native client shell", systemImage: "swift")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.focusComposer()
            } label: {
                Image(systemName: "keyboard")
            }
            .buttonStyle(.borderless)
            .help("Focus message composer")
            .accessibilityLabel("Focus message composer")
            .disabled(model.selectedChannel == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct DetailColumn: View {
    @Bindable var model: ClientModel

    var body: some View {
        Group {
            if model.account == nil {
                AccountDetailEmptyState()
            } else if let channel = model.selectedChannel {
                ChannelView(channel: channel, model: model)
            } else {
                ChannelSelectionEmptyState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AccountDetailEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label("Connect an account", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("Your servers, channels, and messages will appear here after authentication is configured.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connect an account. Your servers, channels, and messages will appear here after authentication is configured.")
    }
}

private struct ChannelSelectionEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label("Select a channel", systemImage: "text.bubble")
        } description: {
            Text("Choose a channel from the sidebar to start reading.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Select a channel. Choose a channel from the sidebar to start reading.")
    }
}
