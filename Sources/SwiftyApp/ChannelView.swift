import SwiftUI

struct ChannelView: View {
    let channel: ClientModel.Channel
    @Bindable var model: ClientModel

    var body: some View {
        VStack(spacing: 0) {
            ChannelHeader(channel: channel, server: model.selectedServer)
            Divider()
            MessageTimeline(channelID: channel.id, messages: model.messages(for: channel))
            Divider()
            Composer(model: model)
        }
    }
}

private struct ChannelHeader: View {
    let channel: ClientModel.Channel
    let server: ClientModel.Server?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "number")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.headline)
                if let topic = channel.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let server {
                    Text(server.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var context = ["Channel \(channel.name)"]
        if let server {
            context.append("in server \(server.name)")
        }
        if let topic = channel.topic, !topic.isEmpty {
            context.append("Topic: \(topic)")
        }
        return context.joined(separator: ". ")
    }
}

private struct MessageTimeline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let channelID: String
    let messages: [ClientModel.Message]
    @State private var isNearBottom = true

    private let bottomThreshold: CGFloat = 96

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if messages.isEmpty {
                            MessageEmptyState()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                        } else {
                            ForEach(messages) { message in
                                MessageRow(message: message)
                                    .id(message.id)
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .background {
                                GeometryReader { bottom in
                                    Color.clear.preference(
                                        key: MessageBottomPreferenceKey.self,
                                        value: bottom.frame(in: .named("message-scroll")).maxY
                                    )
                                }
                            }
                            .id("message-bottom-\(channelID)")
                    }
                    .padding(.vertical, 12)
                }
                .coordinateSpace(name: "message-scroll")
                .id(channelID)
                .defaultScrollAnchor(.bottom)
                .accessibilityLabel("Message history")
                .onPreferenceChange(MessageBottomPreferenceKey.self) { bottomY in
                    isNearBottom = bottomY - viewport.size.height <= bottomThreshold
                }
                .onChange(of: channelID) { _, _ in
                    isNearBottom = true
                }
                .onChange(of: messages.last?.id) { _, lastID in
                    guard let lastID, isNearBottom else { return }
                    if reduceMotion {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    } else {
                        withAnimation(.default) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

private struct MessageBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MessageEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label("No messages yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("New messages in this channel will appear here.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No messages yet. New messages in this channel will appear here.")
    }
}

private struct MessageRow: View {
    let message: ClientModel.Message

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.authorName)
                        .font(.subheadline.weight(.semibold))
                    Text(message.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(message.body)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Message from \(message.authorName) at \(accessibilityTimestamp): \(message.body)")
    }

    private var accessibilityTimestamp: String {
        message.timestamp.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct Composer: View {
    @Bindable var model: ClientModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ComposerTextView(
                text: $model.composerText,
                focusRequested: $model.shouldFocusComposer,
                placeholder: "Message #\(model.selectedChannel?.name ?? "channel")",
                onSubmit: model.sendComposerMessage
            )
            .frame(minHeight: 34, maxHeight: 140)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Message composer")

            Button(action: model.sendComposerMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Send message")
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
