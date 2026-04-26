# Network Audit — August Smart Lock Investigation

**Date:** 2026-03-16
**Subnet:** 192.168.50.0/24
**Router:** ASUS RT-AXE7800 (192.168.50.1)
**Extender:** Netgear EX7300v2 (192.168.50.125) — dual-band 2.4GHz + 5GHz, firmware V1.0.0.146

## Extender Health

| Metric        | Value       |
|---------------|-------------|
| Packet loss   | 0%          |
| Avg latency   | 7.5 ms      |
| Min/Max       | 4.5 / 11.3 ms |
| Web interface | HTTP 200, 162ms |

Extender is healthy. No connectivity issues from the LAN side.

## August Devices: NOT FOUND

Full /24 ping sweep + ARP scan found **zero** devices with August's registered OUI (`78:9C:85`). The lock, keypad, and doorbell cam are not connected to the network.

## Live Devices Found (18 total)

| IP             | Hostname                  | Vendor              |
|----------------|---------------------------|---------------------|
| 192.168.50.1   | rt-axe7800-f7b0           | ASUS (router)       |
| 192.168.50.28  | mill                      | Espressif (IoT)     |
| 192.168.50.41  | mac                       | (this machine)      |
| 192.168.50.42  | samsung                   | Samsung             |
| 192.168.50.53  | octopus                   | Dell                |
| 192.168.50.85  | chinchilla                | HP                  |
| 192.168.50.105 | dingo                     | HP                  |
| 192.168.50.108 | fallicle                  | (private MAC)       |
| 192.168.50.122 | tuneshine-7de8            | Espressif (IoT)     |
| 192.168.50.125 | ex7300v2                  | Netgear (extender)  |
| 192.168.50.142 | bonobo                    | (private MAC)       |
| 192.168.50.177 | codys-airport-extreme     | Apple               |
| 192.168.50.188 | (unnamed)                 | Sony (PlayStation)  |
| 192.168.50.204 | sirver                    | (private MAC)       |
| 192.168.50.224 | sarah-s-z-flip7           | Samsung (phone)     |
| 192.168.50.245 | switchbot-hubmini-638d77  | SwitchBot           |
| 192.168.50.248 | macbookpro                | (private MAC)       |
| 192.168.50.250 | axolotl                   | Dell                |

## Analysis

- August WiFi Smart Lock (4th gen) supports both 2.4GHz and 5GHz (802.11 b/g/n)
- Netgear EX7300v2 broadcasts both bands by default
- Band incompatibility is ruled out
- The August devices simply aren't connecting to WiFi at all
- Lock and keypad communicate via Bluetooth; only the lock (if WiFi model) and doorbell cam use WiFi

## Recommended Next Steps

1. Check August app for WiFi status on the lock
2. Re-run WiFi setup on the lock through the August app while nearby
3. Log into extender admin at http://192.168.50.125 to check client history
4. Check for 2.4GHz channel congestion — many neighbor networks detected on channels 1, 6, 8, 10, 11
5. Consider setting extender to a less congested 2.4GHz channel if the lock connects on 2.4GHz
