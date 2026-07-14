import Foundation

// MARK: - Inbound (agent → client)

/// A decoded line received from `pi --mode rpc` on stdout. The protocol mixes
/// three logical streams on one channel, distinguished by the top-level `type`.
enum RPCInbound: Sendable {
    case response(RPCResponse)
    case event(RPCEvent)
    case uiRequest(ExtUIRequest)
    /// A line we could parse as JSON but didn't recognize — kept for diagnostics.
    case unknown(type: String, raw: JSONValue)

    init(json: JSONValue) {
        let type = json["type"]?.stringValue ?? ""
        switch type {
        case "response":
            self = .response(RPCResponse(json: json))
        case "extension_ui_request":
            self = .uiRequest(ExtUIRequest(json: json))
        default:
            if let event = RPCEvent(type: type, json: json) {
                self = .event(event)
            } else {
                self = .unknown(type: type, raw: json)
            }
        }
    }
}

/// Reply to a command, correlated by the optional `id` we attached on send.
struct RPCResponse: Sendable {
    let id: String?
    let command: String
    let success: Bool
    let error: String?
    let data: JSONValue?

    init(json: JSONValue) {
        id = json["id"]?.stringValue
        command = json["command"]?.stringValue ?? ""
        success = json["success"]?.boolValue ?? false
        error = json["error"]?.stringValue
        data = json["data"]
    }
}

// MARK: - Events (agent lifecycle, streamed asynchronously)

enum RPCEvent: Sendable {
    case agentStart
    case agentEnd
    case turnStart
    case turnEnd
    case messageStart(RawMessage)
    case messageUpdate(RawMessage)
    case messageEnd(RawMessage)
    case toolStart(callId: String, name: String, args: JSONValue?)
    case toolUpdate(callId: String, name: String, partial: String?)
    case toolEnd(callId: String, name: String, output: String, isError: Bool)
    case queueUpdate(steering: [String], followUp: [String])
    case compactionStart(reason: String)
    case compactionEnd(summary: String?, aborted: Bool, error: String?)
    case autoRetryStart(attempt: Int, maxAttempts: Int, delayMs: Int, message: String)
    case autoRetryEnd(success: Bool, attempt: Int, finalError: String?)
    case extensionError(path: String, message: String)

    init?(type: String, json: JSONValue) {
        switch type {
        case "agent_start": self = .agentStart
        case "agent_end": self = .agentEnd
        case "turn_start": self = .turnStart
        case "turn_end": self = .turnEnd
        case "message_start":
            guard let m = json["message"].map(RawMessage.init) else { return nil }
            self = .messageStart(m)
        case "message_update":
            // pi 0.80.x sends both a top-level `message` and the streaming
            // delta's `assistantMessageEvent.partial` (the same partial
            // message). Fall back to the partial so streaming display survives
            // if a future pi drops the redundant top-level copy.
            guard let payload = json["message"] ?? json["assistantMessageEvent"]?["partial"] else { return nil }
            self = .messageUpdate(RawMessage(payload))
        case "message_end":
            guard let m = json["message"].map(RawMessage.init) else { return nil }
            self = .messageEnd(m)
        case "tool_execution_start":
            self = .toolStart(
                callId: json["toolCallId"]?.stringValue ?? "",
                name: json["toolName"]?.stringValue ?? "tool",
                args: json["args"]
            )
        case "tool_execution_update":
            self = .toolUpdate(
                callId: json["toolCallId"]?.stringValue ?? "",
                name: json["toolName"]?.stringValue ?? "tool",
                partial: RPCEvent.extractContentText(json["partialResult"])
            )
        case "tool_execution_end":
            self = .toolEnd(
                callId: json["toolCallId"]?.stringValue ?? "",
                name: json["toolName"]?.stringValue ?? "tool",
                output: RPCEvent.extractContentText(json["result"]) ?? "",
                isError: json["isError"]?.boolValue ?? false
            )
        case "queue_update":
            let steering = (json["steering"]?.arrayValue ?? []).compactMap(\.stringValue)
            let followUp = (json["followUp"]?.arrayValue ?? []).compactMap(\.stringValue)
            self = .queueUpdate(steering: steering, followUp: followUp)
        case "compaction_start":
            self = .compactionStart(reason: json["reason"]?.stringValue ?? "")
        case "compaction_end":
            self = .compactionEnd(
                summary: json["result"]?["summary"]?.stringValue,
                aborted: json["aborted"]?.boolValue ?? false,
                error: json["errorMessage"]?.stringValue
            )
        case "auto_retry_start":
            self = .autoRetryStart(
                attempt: json["attempt"]?.intValue ?? 0,
                maxAttempts: json["maxAttempts"]?.intValue ?? 0,
                delayMs: json["delayMs"]?.intValue ?? 0,
                message: json["errorMessage"]?.stringValue ?? ""
            )
        case "auto_retry_end":
            self = .autoRetryEnd(
                success: json["success"]?.boolValue ?? false,
                attempt: json["attempt"]?.intValue ?? 0,
                finalError: json["finalError"]?.stringValue
            )
        case "extension_error":
            self = .extensionError(
                path: json["extensionPath"]?.stringValue ?? "",
                message: json["error"]?.stringValue ?? ""
            )
        default:
            return nil
        }
    }

    /// Tool results carry `content: [{type:"text", text:"…"}]`. Flatten the
    /// text blocks into a single string for display.
    static func extractContentText(_ value: JSONValue?) -> String? {
        guard let blocks = value?["content"]?.arrayValue else { return nil }
        let texts = blocks.compactMap { $0["text"]?.stringValue }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
}

// MARK: - Messages

/// A pi conversation message in its on-the-wire form. We only decode the
/// fields the UI needs; everything else is ignored.
struct RawMessage: Sendable {
    let role: String
    /// Ordered content blocks (assistant messages) or a single text block
    /// synthesized from a string `content` (user messages).
    let blocks: [RawBlock]
    /// Why the model stopped. `"error"` means the request failed and `content`
    /// is empty — the failure detail lives in `errorMessage`.
    let stopReason: String?
    /// Provider/API error text when the turn failed (e.g. a 4xx body). Present
    /// only alongside `stopReason == "error"`.
    let errorMessage: String?

    /// True when the model errored out before producing any content, so the UI
    /// should surface `errorMessage` instead of rendering an empty bubble.
    var isError: Bool { stopReason == "error" }

    init(_ json: JSONValue) {
        role = json["role"]?.stringValue ?? "assistant"
        stopReason = json["stopReason"]?.stringValue
        errorMessage = json["errorMessage"]?.stringValue
        if let content = json["content"] {
            switch content {
            case .string(let s):
                blocks = [RawBlock(type: "text", text: s, thinking: nil, name: nil, id: nil)]
            case .array(let arr):
                blocks = arr.map(RawBlock.init)
            default:
                blocks = []
            }
        } else {
            blocks = []
        }
    }

    var textSegments: [TextSegment] {
        blocks.compactMap { block in
            switch block.type {
            case "text":
                guard let t = block.text, !t.isEmpty else { return nil }
                return .text(t)
            case "thinking":
                guard let t = block.thinking, !t.isEmpty else { return nil }
                return .thinking(t)
            default:
                return nil
            }
        }
    }
}

struct RawBlock: Sendable {
    let type: String
    let text: String?
    let thinking: String?
    let name: String?
    let id: String?

    init(_ json: JSONValue) {
        type = json["type"]?.stringValue ?? ""
        text = json["text"]?.stringValue
        thinking = json["thinking"]?.stringValue
        name = json["name"]?.stringValue
        id = json["id"]?.stringValue
    }

    init(type: String, text: String?, thinking: String?, name: String?, id: String?) {
        self.type = type; self.text = text; self.thinking = thinking; self.name = name; self.id = id
    }
}

enum TextSegment: Sendable, Equatable {
    case text(String)
    case thinking(String)
}

// MARK: - Extension UI sub-protocol

/// A request from an extension for user interaction (e.g. tool approval).
struct ExtUIRequest: Sendable, Identifiable {
    let id: String
    let method: String          // select | confirm | input | editor | notify | setStatus | …
    let title: String?
    let message: String?
    let options: [String]
    let placeholder: String?
    let prefill: String?
    let notifyType: String?
    // Fire-and-forget footer/widget surfaces (setStatus / setWidget). A `nil`
    // text/lines means "clear that key".
    let statusKey: String?
    let statusText: String?
    let widgetKey: String?
    let widgetLines: [String]?

    init(json: JSONValue) {
        id = json["id"]?.stringValue ?? UUID().uuidString
        method = json["method"]?.stringValue ?? ""
        title = json["title"]?.stringValue
        message = json["message"]?.stringValue
        options = (json["options"]?.arrayValue ?? []).compactMap(\.stringValue)
        placeholder = json["placeholder"]?.stringValue
        prefill = json["prefill"]?.stringValue
        notifyType = json["notifyType"]?.stringValue
        statusKey = json["statusKey"]?.stringValue
        statusText = json["statusText"]?.stringValue
        widgetKey = json["widgetKey"]?.stringValue
        widgetLines = json["widgetLines"]?.arrayValue?.compactMap(\.stringValue)
    }

    /// Dialog methods block the agent until we reply; fire-and-forget ones don't.
    var isDialog: Bool {
        ["select", "confirm", "input", "editor"].contains(method)
    }
}

// MARK: - Model metadata

struct PiModel: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let provider: String
    let reasoning: Bool
    let contextWindow: Int?
    /// Accepted input modalities, e.g. `["text", "image"]`. Empty when the agent
    /// doesn't report them (treated as text-only).
    let inputModalities: [String]

    init?(_ json: JSONValue?) {
        guard let json, let id = json["id"]?.stringValue else { return nil }
        self.id = id
        self.name = json["name"]?.stringValue ?? id
        self.provider = json["provider"]?.stringValue ?? ""
        self.reasoning = json["reasoning"]?.boolValue ?? false
        self.contextWindow = json["contextWindow"]?.intValue
        self.inputModalities = (json["input"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    /// Whether this model can accept image input (multimodal). Drives whether the
    /// composer offers image attachment at all.
    var supportsImages: Bool { inputModalities.contains("image") }

    var displayLabel: String { "\(name)" }
    var qualified: String { provider.isEmpty ? id : "\(provider)/\(id)" }

    /// Asset-catalog name of the provider's brand glyph, or `nil` to fall back
    /// to an SF Symbol. Matches on provider first, then the model id.
    var logoAssetName: String? {
        let haystack = "\(provider) \(id)".lowercased()
        if haystack.contains("anthropic") || haystack.contains("claude") { return "ProviderAnthropic" }
        if haystack.contains("openai") || haystack.contains("gpt") || haystack.contains("codex") || haystack.contains("o1") || haystack.contains("o3") { return "ProviderOpenAI" }
        if haystack.contains("google") || haystack.contains("gemini") { return "ProviderGemini" }
        if haystack.contains("deepseek") { return "ProviderDeepSeek" }
        return nil
    }
}

/// An invocable command reported by `get_commands`: an extension command, a
/// prompt template, or a skill. Invoked by sending `/name` as a `prompt`.
struct PiCommand: Sendable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let description: String?
    /// `"extension"`, `"prompt"`, or `"skill"`.
    let source: String
    /// Where it was loaded from: `"user"`, `"project"`, or `"path"` (absent for
    /// extension commands).
    let location: String?
    let path: String?

    init?(_ json: JSONValue?) {
        guard let json, let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        self.description = json["description"]?.stringValue
        self.source = json["source"]?.stringValue ?? "extension"
        self.location = json["location"]?.stringValue
        self.path = json["path"]?.stringValue
    }

    /// Client-side (builtin) commands the app injects into the palette itself.
    init(name: String, description: String?, source: String, location: String? = nil, path: String? = nil) {
        self.name = name
        self.description = description
        self.source = source
        self.location = location
        self.path = path
    }

    /// Preferred grouping order for the palette; unknowns sort last.
    var sourceRank: Int {
        switch source {
        case "extension": return 0
        case "prompt": return 1
        case "skill": return 2
        default: return 3
        }
    }
}

struct SessionStats: Sendable {
    var totalTokens: Int
    var cost: Double
    var contextPercent: Int?
    var contextTokens: Int?
    var contextWindow: Int?

    init?(_ json: JSONValue?) {
        guard let json else { return nil }
        totalTokens = json["tokens"]?["total"]?.intValue ?? 0
        cost = json["cost"]?.doubleValue ?? 0
        contextPercent = json["contextUsage"]?["percent"]?.intValue
        contextTokens = json["contextUsage"]?["tokens"]?.intValue
        contextWindow = json["contextUsage"]?["contextWindow"]?.intValue
    }
}
