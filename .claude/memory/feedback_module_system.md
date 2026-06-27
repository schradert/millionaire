---
name: feedback_module_system
description: Prefer nixidy module system for cross-cutting config rather than helper functions or centralized definitions
type: feedback
---

When configuring cross-cutting concerns (like gatus endpoints for each service), define them in each service's own file using the module system — not centralized in one file with helper functions.

**Why:** User wants each app to be self-contained. Centralizing config in one file couples things and makes it harder to see what an app exposes.
**How to apply:** Use shared nixidy options (like `gatus.endpoints`) that each app file contributes to, with dynamic defaults derived from other module config where possible.
