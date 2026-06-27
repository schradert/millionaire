---
name: Ask before acting on ambiguous statements
description: Don't interpret rhetorical questions or ambiguous statements as instructions to change code
type: feedback
---

When the user makes an ambiguous statement or asks a question about whether something should be a certain way, ask for clarification rather than immediately making changes. Don't assume a question is an instruction.

**Why:** User got frustrated when a question ("home-assistant shouldn't use postgres or anything?") was interpreted as an instruction to remove postgres, when they were actually confirming it should stay.

**How to apply:** If a user's message could be either a question or an instruction, treat it as a question and clarify before editing code.
