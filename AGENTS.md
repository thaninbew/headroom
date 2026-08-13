# Headroom

Headroom is a standalone open-source macOS app, not a Chappie component.

- Keep enforcement event-driven. Never add background quota polling or usage
  prediction.
- Use documented Codex lifecycle hooks and app-server RPCs by default.
- Do not enforce through `PreToolUse`; Codex feeds its denial back to the model.
- Building and testing must never install hooks or edit the user's Codex config.
- Installation must preserve unrelated hooks; uninstallation removes only
  Headroom-owned entries.
- Meter failures fail open and surface an actionable error.
