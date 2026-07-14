/**
 * Plan Mode Extension (Pi Liquid — opencode-style)
 *
 * A read-only exploration mode. While enabled, the built-in write tools are
 * disabled and bash is restricted to an allowlist, so the agent can only
 * analyze the codebase and *describe* a plan — it can't touch files.
 *
 * Unlike the stock example, this build does NOT parse the plan text or run an
 * "execute the plan" flow. The plan is just the agent's prose. Pi Liquid hands
 * that plan to a fresh session to carry out (see SessionManager.executePlan),
 * which keeps the executing context clean and avoids brittle text extraction.
 *
 * Surface:
 * - `/plan` command or Ctrl+Alt+P toggles plan mode.
 * - `--plan` flag starts a session in plan mode.
 * - A `plan-mode` footer status is posted so the app can show its Plan chip.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Key } from "@earendil-works/pi-tui";
import { isSafeCommand } from "./utils.ts";

// Read-only toolset while planning; the normal set to restore afterwards.
const PLAN_MODE_TOOLS = ["read", "bash", "grep", "find", "ls", "questionnaire"];
const NORMAL_MODE_TOOLS = ["read", "bash", "edit", "write"];
const PLAN_MODE_DISABLED_TOOLS = new Set<string>(["edit", "write"]);
const PLAN_MANAGED_TOOLS = new Set<string>([...PLAN_MODE_TOOLS, ...NORMAL_MODE_TOOLS]);

interface PlanModeState {
	enabled: boolean;
	toolsBeforePlanMode?: string[];
}

export default function planModeExtension(pi: ExtensionAPI): void {
	let planModeEnabled = false;
	let toolsBeforePlanMode: string[] | undefined;

	pi.registerFlag("plan", {
		description: "Start in plan mode (read-only exploration)",
		type: "boolean",
		default: false,
	});

	function updateStatus(ctx: ExtensionContext): void {
		ctx.ui.setStatus("plan-mode", planModeEnabled ? ctx.ui.theme.fg("warning", "⏸ plan") : undefined);
	}

	function uniqueToolNames(toolNames: string[]): string[] {
		return [...new Set(toolNames)];
	}

	function getPlanModeTools(activeToolNames: string[]): string[] {
		return uniqueToolNames([
			...activeToolNames.filter((name) => !PLAN_MODE_DISABLED_TOOLS.has(name)),
			...PLAN_MODE_TOOLS,
		]);
	}

	function getNormalModeTools(activeToolNames: string[]): string[] {
		return uniqueToolNames([
			...NORMAL_MODE_TOOLS,
			...activeToolNames.filter((name) => !PLAN_MANAGED_TOOLS.has(name)),
		]);
	}

	function enablePlanModeTools(): void {
		if (toolsBeforePlanMode === undefined) {
			toolsBeforePlanMode = pi.getActiveTools();
		}
		pi.setActiveTools(getPlanModeTools(toolsBeforePlanMode));
	}

	function restoreNormalModeTools(): void {
		pi.setActiveTools(toolsBeforePlanMode ?? getNormalModeTools(pi.getActiveTools()));
		toolsBeforePlanMode = undefined;
	}

	function persistState(): void {
		pi.appendEntry("plan-mode", { enabled: planModeEnabled, toolsBeforePlanMode } satisfies PlanModeState);
	}

	function togglePlanMode(ctx: ExtensionContext): void {
		planModeEnabled = !planModeEnabled;
		if (planModeEnabled) {
			enablePlanModeTools();
		} else {
			restoreNormalModeTools();
		}
		updateStatus(ctx);
		persistState();
	}

	pi.registerCommand("plan", {
		description: "Toggle plan mode (read-only exploration); `/plan <prompt>` enables it and asks right away",
		handler: async (args, ctx) => {
			const prompt = (args ?? "").trim();
			if (prompt.length === 0) {
				togglePlanMode(ctx);
				return;
			}
			// `/plan <prompt>`: without this, the trailing text was silently
			// dropped — the mode toggled but no turn ran, which looked like a
			// dead app. Enable (never disable) and submit the prompt.
			if (!planModeEnabled) {
				togglePlanMode(ctx);
			}
			pi.sendUserMessage(prompt);
		},
	});

	pi.registerShortcut(Key.ctrlAlt("p"), {
		description: "Toggle plan mode",
		handler: async (ctx) => togglePlanMode(ctx),
	});

	// Block destructive bash commands while planning (read-only safety).
	pi.on("tool_call", async (event) => {
		if (!planModeEnabled || event.toolName !== "bash") return;
		const command = event.input.command as string;
		if (!isSafeCommand(command)) {
			return {
				block: true,
				reason: `Plan mode: command blocked (not allowlisted). Disable plan mode to run it.\nCommand: ${command}`,
			};
		}
	});

	// Strip stale plan-mode context once plan mode is off.
	pi.on("context", async (event) => {
		if (planModeEnabled) return;
		return {
			messages: event.messages.filter((m) => {
				const msg = m as { customType?: string };
				return msg.customType !== "plan-mode-context";
			}),
		};
	});

	// Steer the model toward a read-only plan while planning.
	pi.on("before_agent_start", async () => {
		if (!planModeEnabled) return;
		return {
			message: {
				customType: "plan-mode-context",
				content: `[PLAN MODE ACTIVE]
You are in plan mode — a read-only exploration mode for safe analysis.

Restrictions:
- Built-in edit and write tools are disabled.
- Bash is restricted to an allowlist of read-only commands.

Explore the codebase as needed, then produce a clear, actionable implementation
plan: what you would change, in which files, and in what order. Prefer a concise
numbered list of concrete steps. Do NOT attempt to make changes — only describe
what you would do. The user will execute the plan separately.`,
				display: false,
			},
		};
	});

	// Restore plan-mode state on session start / resume.
	pi.on("session_start", async (_event, ctx) => {
		if (pi.getFlag("plan") === true) {
			planModeEnabled = true;
		}

		const entries = ctx.sessionManager.getEntries();
		const planModeEntry = entries
			.filter((e: { type: string; customType?: string }) => e.type === "custom" && e.customType === "plan-mode")
			.pop() as { data?: PlanModeState } | undefined;
		if (planModeEntry?.data) {
			planModeEnabled = planModeEntry.data.enabled ?? planModeEnabled;
			toolsBeforePlanMode = planModeEntry.data.toolsBeforePlanMode ?? toolsBeforePlanMode;
		}

		if (planModeEnabled) {
			enablePlanModeTools();
		}
		updateStatus(ctx);
	});
}
