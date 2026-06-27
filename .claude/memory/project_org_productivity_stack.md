---
name: Org-mode productivity stack
description: Self-hosted org-mode task/calendar system with Syncthing, Baïkal CalDAV, WebDAV, org-bridge, and multi-client access
type: project
---

Building a self-hosted productivity stack centered on org-mode files as canonical task/scheduling data.

**Architecture decisions (2026-03-22):**
- Hybrid Ceph storage: CephFS (RWX) for shared org files, RBD (RWO) for per-service state
- Syncthing as centralized hub on k8s (all devices sync through server, relay-only — no NodePort)
- Baïkal for CalDAV/CardDAV (lightweight, sabre/dav based)
- hacdias/webdav for organice (mobile PWA) access to .org files
- org-bridge: Python daemon using Syncthing Events API, exports VEVENTs to Baïkal CalDAV (one-way)
- org-bridge container built with Nix dockerTools
- Fossify Calendar + DAVx5 on mobile: read-only calendar view
- khal + vdirsyncer on desktop: read-only TUI calendar
- All services in `home` namespace

**Why:** User wants ClickUp-like task management but self-hosted, document-based (org-mode), with mobile calendar view, time tracking, and multi-client access. No single OSS tool covers all requirements — composable stack is the answer.

**How to apply:** When working on productivity/calendar/task features, reference this architecture. org-mode is source of truth, CalDAV is read-only export.
