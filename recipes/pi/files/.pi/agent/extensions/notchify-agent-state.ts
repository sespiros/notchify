import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawnSync } from "node:child_process";

// notchify-agent-state: fire a notchify popup when Pi finishes work.
//
// Pi auto-discovers this file from ~/.pi/agent/extensions/*.ts on
// startup or after /reload. No config-file registration is needed.
//
// Fires one notification per user prompt when the agent becomes idle
// (agent_end). Debounces within DEBOUNCE_SECS so multi-turn prompts
// (several tool-call rounds without user input) don't spam.

const DEBOUNCE_SECS = 5;
const HOME = process.env.HOME ?? "";

export default function (pi: ExtensionAPI) {
  let lastFired: number | null = null;

  pi.on("agent_end", (_event) => {
    const now = Date.now();
    if (lastFired !== null && now - lastFired < DEBOUNCE_SECS * 1000) {
      return;
    }
    lastFired = now;

    const title = buildTitle();
    const body = "done";
    const group = "pi:done";
    const icon = `${HOME}/.config/pi/icons/done.png`;

    // Run synchronously: backgrounding reparents notchify to launchd,
    // breaking getppid()-based bundle detection used by --focus.
    try {
      spawnSync(
        "notchify",
        [title, body, "--sound", "ready", "--icon", icon, "--group", group, "--focus"],
        { stdio: "ignore", env: process.env }
      );
    } catch {
      // ENOENT, EPERM, missing icon, etc. must stay silent and not
      // crash the agent.
    }
  });
}

function buildTitle(): string {
  // With tmux, qualify "pi" with session:window so the user can
  // tell concurrent sessions apart; without tmux, fall back to bare
  // "pi".
  let title = "pi";
  const tmuxPane = process.env.TMUX_PANE;
  if (tmuxPane && tmuxPane.length > 0) {
    const result = spawnSync(
      "tmux",
      ["display-message", "-pt", tmuxPane, "#{session_name}:#{window_name}"],
      { encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"] }
    );
    if (result.status === 0) {
      const loc = result.stdout?.replace(/\n$/, "").trim();
      if (loc && loc.length > 0) {
        title = `pi ${loc}`;
      }
    }
  }
  return title;
}
