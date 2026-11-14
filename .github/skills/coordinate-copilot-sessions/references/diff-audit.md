# Diff Audit Checklist (Hard Rule #3: Zero Bloat / Zero Over-Engineering Gate)

Load this every time you audit a child's merge-base diff, including before declaring the PR done. Hard Rule numbers refer to [`SKILL.md`](../SKILL.md). The audit steps are Workflow step 5 in [`references/monitor.md`](monitor.md).

Specifically check for and reject:

- Speculative config flags.
- Unnecessary wrapper classes/helpers.
- Regex error-message parsers where typed unwrapping works.
- Redundant validation layers.
- Defensive patches of more than 15 lines for hypothetical review nitpicks.
