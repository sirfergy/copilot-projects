# Spin Off / Fork a Tangent (Standalone Handoff)

Load this when the user asks to extract, spin off, or fork a tangent into its own session or tab.

Use this mode when a conversation uncovers a side question, skill idea, or follow-up track and the user wants to move it into its own tab without distracting from the current session's main work.

`SKILL_DIR` is the directory the skill's `SKILL.md` was loaded from (for example `~/.copilot/skills/coordinate-copilot-sessions` or `<repo>/.github/skills/coordinate-copilot-sessions`).

1. **Resolve the best target project for the tangent:**
   Pick the project that matches the tangent's domain (e.g., `Skills` for skill authoring, `Reliability`, `Quality`, `Features`, or fall back to the current project if none is more specific):
   ```bash
   PROJECT_ID=$(python3 "$SKILL_DIR/scripts/coordinator.py" resolve-project --name "Skills")
   ```
2. **Write a self-contained handoff prompt (`<= 8192` UTF-8 bytes):**
   Write a prompt file in the current session's `files/` directory so the user never has to repeat context in the new tab. Include:
   - **Why it was spun off** (and the originating session ID for reference only).
   - **Existing artifacts & state** already created during the tangent (commits, worktrees, file paths, PR URLs, or links).
   - **Exact open question or remaining tasks** that the new session now owns end-to-end.
3. **Launch with `--no-parent` and hand off cleanly:**
   Pass `--no-parent` so the spun-off tangent opens as a standalone top-level tab in its target project rather than a child grouped under the unrelated originating session:
   ```bash
   python3 "$SKILL_DIR/scripts/coordinator.py" launch \
     --project "$PROJECT_ID" \
     --no-parent \
     --title "<Short Tangent Title>" \
     --prompt-file "$SESSION_FILES/handoff-prompt.md"
   ```
   Once `coordinator.py launch` returns `status: "running"`, report the **Project**, **Tab Title**, and **Session ID** to the user and immediately return the current session's focus to its primary task. Do **not** poll, coordinate, or steer the spun-off tangent from the originating session.
