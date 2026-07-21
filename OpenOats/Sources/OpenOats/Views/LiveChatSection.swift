import SwiftUI

/// Collapsible chat panel shown in the main window during a recording. Each
/// question is answered from a transcript snapshot taken at the moment it is
/// sent.
struct LiveChatSection: View {
    let engine: LiveChatEngine
    let speakerNames: [String: String]

    @AppStorage("isLiveChatExpanded") private var isExpanded = false
    @State private var draft = ""

    private static let bottomID = "liveChatBottom"

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 0) {
                messageList
                inputBar
            }
            .frame(height: 250)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
        } label: {
            HStack(spacing: 6) {
                Text("Ask")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if !engine.messages.isEmpty {
                    Text("(\(engine.messages.count))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if engine.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Ask about the meeting so far", systemImage: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Answers use a snapshot of the transcript taken the moment you hit send.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 6)
                    }

                    ForEach(engine.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if engine.isResponding, engine.messages.last?.role != .assistant {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Reading transcript...")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 2)
                    }

                    if let error = engine.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 2)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: engine.messages.count) {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onChange(of: engine.messages.last?.text) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private func messageBubble(_ message: LiveChatMessage) -> some View {
        let isUser = message.role == .user

        return HStack {
            if isUser {
                Spacer(minLength: 32)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(isUser ? "You" : "OpenOats")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(message.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isUser ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isUser ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), lineWidth: 1)
            )

            if !isUser {
                Spacer(minLength: 32)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Did I miss something? Ask...", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit(send)

            if engine.isResponding {
                Button {
                    engine.cancel()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Stop responding")
            } else {
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !engine.isResponding else { return }
        draft = ""
        engine.send(question, speakerNames: speakerNames)
    }
}
