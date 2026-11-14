# Diff Audit Checklist (Hard Rule #3: Zero Bloat / Zero Over-Engineering Gate)

Load this every time you audit a child's merge-base diff, including before declaring the PR done. Hard Rule numbers refer to [`SKILL.md`](../SKILL.md). The audit steps are Workflow step 5 in [`references/monitor.md`](monitor.md).

Specifically check for and reject:

- **Speculative guards, fallbacks, dead plumbing, or duplication:** speculative edge-case guards, redundant fallbacks, dead plumbing, unnecessary abstractions, or cross-track duplication.
- **Speculative flags, wrappers, parsers, or defensive patches:** speculative config flags, unnecessary wrapper classes/helpers, regex error-message parsers where typed unwrapping works, redundant validation layers, or >15-line defensive patches for hypothetical review nitpicks.
