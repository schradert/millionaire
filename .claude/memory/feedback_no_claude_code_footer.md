---
name: No "Generated with Claude Code" footer
description: Omit the "🤖 Generated with [Claude Code](https://claude.com/claude-code)" footer from PR bodies and commit messages.
type: feedback
originSessionId: fbaddef6-642c-43b9-806e-6b3370808242
---
Do not include the "🤖 Generated with [Claude Code](https://claude.com/claude-code)" footer in PR descriptions or commit messages for this repo.

**Why:** User preference — they don't want their PRs/commits advertising the tool; the `Co-Authored-By` trailer in commits already conveys authorship.

**How to apply:** When running `gh pr create`, skip the trailing footer block. Keep commit `Co-Authored-By: Claude ...` trailers if the standard commit workflow calls for them, but no trailing marketing line in PR bodies.
