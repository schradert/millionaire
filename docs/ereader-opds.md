# E-Reader Access: OPDS Bypass + ESP32 Tailscale Feasibility (2026-06-10)

## Problem

Kavita and Komga sit behind oauth2-proxy (OIDC). E-reader OPDS clients can
only do HTTP Basic auth or URL-embedded API keys — they cannot complete an
OIDC redirect flow. The Xteink X4 (ESP32-C3) additionally cannot run a real
Tailscale client (measured below), so a tailnet-only exposure doesn't cover
every reading device.

## What Was Configured

Gateway-API HTTPRoutes that send OPDS path prefixes directly to the app
services, skipping oauth2-proxy. Longest-path-match precedence (Gateway API
spec) means these win over the catch-all oauth2-proxy rule for the same
hostname; everything else (web UI, API) stays behind SSO.

| App | Bypassed prefixes | App-side auth on those paths |
| --- | --- | --- |
| Kavita | `/api/opds`, `/api/image` | Per-user API key in the URL path (401 without); downloads also need download permission. `/api/image` cover endpoints are `[AllowAnonymous]` upstream — see exposure note. |
| Komga | `/opds` | HTTP Basic / `X-API-Key` on every endpoint (Spring Security `authenticated()` on `/opds/**`); downloads gated by `FILE_DOWNLOAD`, page streaming by `PAGE_STREAMING`. |

Both apps' OPDS feeds are fully self-contained under these prefixes
(verified in Kavita v0.8.9 and Komga v1.24.1 source): feed navigation,
cover thumbnails, book downloads, and OPDS-PSE page streaming never link
outside them.

### Exposure accepted

- **Kavita `/api/image`**: cover endpoints ignore the apiKey, so anyone who
  can reach the internal gateway can fetch cover art by iterating numeric
  ids. Book files, feed text, and page content remain key-gated. Accepted
  as low-severity on an internal-only gateway.
- **Komga Basic auth**: becomes an online brute-force surface (Komga has no
  built-in lockout). Internal-only gateway + strong passwords accepted.
- API keys ride in URL paths/queries → they appear in access logs.

### Client URLs

- Kavita: `https://kavita.<domain>/api/opds/{apiKey}` — per-user key under
  Settings → 3rd Party Clients / OPDS. OPDS is on by default in v0.8.9.
- Komga: `https://komga.<domain>/opds/v1.2/catalog` (Atom) or
  `/opds/v2/catalog` (JSON). Komga account email + password as Basic auth.

### Per-device

- **Xteink X4 (crosspoint-reader)**: mainline crosspoint-reader already
  ships an OPDS browser (up to 8 saved servers, search, pagination,
  download) — point it at the Kavita URL above. Nothing to flash or fork.
  Caveat to verify on-device: TLS trust for the gateway certificate
  (issue #2111 upstream tracks OPDS-over-http breakage in v1.3.0).
- **Android devices**: any OPDS reader (KOReader, Librera, Moon+) works
  with the same URLs; these can also just use Tailscale + SSO normally.

## ESP32 Tailscale Feasibility (falcon experiments, 2026-06-10)

Build-size experiments run on falcon (NixOS, Docker + nix-ld available)
against the boards on its USB hub: 3× ESP32-C3 (4MB flash, native USB-JTAG)
and 2× ESP32-S3 (8MB flash, CP2102N). Serial access requires sudo (user not
in `dialout`). Artifacts under `/tmp/esp-feas/` on falcon.

### MicroLink (real Tailscale client, github.com/CamM2325/microlink)

| Target | Build | App flash | Static RAM (link-time) |
| --- | --- | --- | --- |
| esp32s3 (stock, octal PSRAM) | ✅ | 1.05MB | 137KB internal (incl. RAM-resident code) |
| esp32c3 (no-PSRAM profile) | ✅ first known C3 build | 1.10MB | 113KB unified DRAM |

- C3 build needed only the README's documented no-PSRAM profile
  (`ML_H2_BUFFER_SIZE_KB=64`, `ML_JSON_BUFFER_SIZE_KB=64`, `ML_MAX_PEERS=8`);
  no Xtensa-specific code. Upstream lists C3 as "should work, untested".
- The killer is the MapResponse parse: two contiguous 64KB heap buffers
  (~128KB spike) even in the minimum configuration.
- **Standalone on a bare C3**: marginal — ~100-110KB heap remains after
  WiFi + task stacks, vs a 128KB spike. Might work with code changes
  (streaming JSON parse); not today.
- **Alongside crosspoint-reader on the X4**: not feasible. The reader
  measures 168KB static of 321KB usable SRAM (~153KB total heap before its
  48KB framebuffer, WiFi buffers, and SD caching), and its own docs treat
  largest-contiguous-free-block as the binding constraint. Also a framework
  mismatch: MicroLink is ESP-IDF v5 components; crosspoint is Arduino/pioarduino.

### crosspoint-reader (X4 firmware, measured on the exact C3 target)

- Flash: 5.19MB of the 6.55MB OTA slot → ~1.3MB headroom. The OPDS client
  (TLS + Atom parsing + downloads) is already included in that figure.
- SRAM: 168KB static of 321KB usable (PIO's "30.9% RAM" headline excludes
  RAM-resident code). Runtime free heap with a book open is realistically
  30-70KB with poor contiguity.

### esp32-tailbridge (plain WireGuard + Linux-side proxy)

- ESP32 side is only esp_wireguard (single peer): ~26KB flash, ~1-2KB RAM
  on top of an existing firmware — would drop into crosspoint-reader's
  toolchain (same pioarduino/Arduino 3.x) if ever wanted.
- Costs: a persistent Linux proxy terminates WG and bridges to the tailnet
  (subnet-router mode, or one tailscaled netns per device at ~80MB each for
  first-class nodes); traffic hairpins through it; proxy sees plaintext;
  static manually-provisioned keys. Upstream repo needed trivial patches to
  build at all (missing WiFi include, no C3 env).

### Verdict

OPDS bypass + the X4's native OPDS browser is the complete solution — the
device never needs to be on the tailnet. Tailscale-on-ESP32 is real now
(MicroLink builds and plausibly runs standalone on C3), but not inside a
380KB-budget reader firmware. If LAN-independent access to the X4 ever
matters, esp32-tailbridge's WG-only approach is the only fit, at the cost
of a proxy hop.
