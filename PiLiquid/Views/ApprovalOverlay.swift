import SwiftUI

/// Modal glass card that fulfils pi's extension UI dialog requests
/// (`select`, `confirm`, `input`, `editor`) — most commonly tool approvals.
struct ApprovalOverlay: View {
    let request: ExtUIRequest
    @Environment(ChatModel.self) private var model
    @State private var inputText = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.2))
                .ignoresSafeArea()
                .onTapGesture { model.cancelUI() }

            VStack(alignment: .leading, spacing: DS.md) {
                if let title = request.title {
                    Text(title)
                        .font(.title3.weight(.semibold))
                }
                if let message = request.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                content

                actions
            }
            .padding(DS.lg)
            .frame(width: 440)
            .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusLarge))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusLarge)
                    .strokeBorder(DS.hairline.opacity(0.5), lineWidth: 1)
            )
        }
        .onAppear {
            inputText = request.prefill ?? ""
            if request.method == "input" || request.method == "editor" { focused = true }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch request.method {
        case "input":
            TextField(request.placeholder ?? "", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { model.resolveUI(value: inputText) }
        case "editor":
            TextEditor(text: $inputText)
                .font(.mono(13))
                .frame(height: 180)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(DS.chipFill, in: .rect(cornerRadius: DS.radiusSmall))
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch request.method {
        case "select":
            VStack(spacing: DS.xs) {
                ForEach(Array(request.options.enumerated()), id: \.offset) { _, option in
                    Button {
                        model.resolveUI(value: option)
                    } label: {
                        Text(option).frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.glass)
                }
            }
        case "confirm":
            HStack(spacing: DS.xs) {
                Button("Cancel") { model.resolveUI(confirmed: false) }
                    .controlSize(.large)
                    .buttonStyle(.glass)
                Button("Confirm") { model.resolveUI(confirmed: true) }
                    .controlSize(.large)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case "input", "editor":
            HStack(spacing: DS.xs) {
                Button("Cancel") { model.cancelUI() }
                    .controlSize(.large)
                    .buttonStyle(.glass)
                Button("Submit") { model.resolveUI(value: inputText) }
                    .controlSize(.large)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        default:
            Button("Dismiss") { model.cancelUI() }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
