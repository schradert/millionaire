# Secrets: Bitwarden at activation (README todo 15)

Goal: Bitwarden Secrets Manager (BWS) is the only store. No `secrets/sops/`, no `.sops.yaml`, no age keys, no `*_sops_write` pulumi commands.
Hosts fetch their own secrets at boot and on every switch. This page is the design and the staged plan; stage 1 (the module and one pilot) is in the repo.

## Today (checked 2026-10-16)

- `secrets/sops/default.yaml` (recipients: tristan, the `&server` key, falcon, axolotl, muffin, piper): `passwords/{age,k8s-token}`, `bitwarden` (the admin machine token), `b2/{id,key}`,
  `attic/{server-key,auth-token}`, `adguard/admin/password-hash`, `headscale/preauth-key/cluster-node`, `cloudflare/account/token`, plus `ntfy/*`, `backblaze/bucket/*`, `android/adb-key` once pulumi has written them.
- `personal.yaml` (tristan, falcon, axolotl, deck, echidna, gargoyle): `headscale/preauth-key/{personal,family}`, `api/{anthropic,context7,openai}`, `ssh/personal`, `age/{tristan,bws-backup}`, `ntfy/reader/token`.
- `hostkeys.yaml` (tristan only): private ssh host keys of piper, echidna, gargoyle. `syncthing-<host>.yaml`: one device identity per host.
- Consumers: `flake.nix` (atticd key, adb key), `static/{hyena,ntfy,headscale-backup,attic-server,k8s-node,tailnet,tailnet-personal,cloud-worker,echidna,gargoyle,muffin,muffin-vm,axolotl,falcon-system}.nix`,
  `static/host-key.sh`, `modules/{api-keys,opencode,ntfy,workstation-keys,syncthing,tailnet,git,ssh}.nix`, `devenv.nix` (BWS token, B2 keys, `syncthing-identity`, restore tests),
  `nixidy/system/security/external-secrets/bitwarden.nix` (the BWS token into the cluster at render time, `vals ref+sops`), `pulumi/` (`passwords.age` into nixos-anywhere `--extra-files`, `k8s-token`, 10 sops-writing commands (`*_sops_write`, `*_key_sops`)).
- canivete itself wires sops: `modules/sops/default.nix` imports sops-nix into every NixOS, darwin and home-manager system, and `modules/kubernetes/default.nix` points `canivete.kubernetes.yaml.token-file` at `passwords/k8s-token`.
- Roots of trust: tristan's age key on the Macs (docs/manual-steps.md 12), and each host's ssh host key (a sops recipient).
- Costs of that: every new value is a pulumi run plus a commit; a missing key fails the whole host build, hence the `hasInfix` gates in `flake.nix`, `static/ntfy.nix`, `static/headscale-backup.nix`, `modules/ntfy.nix`; a new host needs `sops updatekeys`;
  the `builtins.path` sops files are why `nix flake check --no-build` fails (README 1).

## Model

```
pulumi / `bws` (write)  ->  BWS projects  <-(read-only machine token, one per host or tier)-  host: bws-secrets -> /run/secrets/<name>
                                                                                                   |  age-encrypted cache (host ssh key)
```

- A secret is a BWS secret whose `key` is its name (`attic/auth-token`), exactly as the cluster's ExternalSecrets already address them.
- A host reads only the project(s) its machine account is granted. The value reaches the host at activation, never the repo or the nix store.
- Missing keys no longer break builds: they fail that one secret at runtime (visible as a failed `bws-secrets.service`), so the eval-time gates go away.

### Projects and machine accounts

| Project | Holds | Read by |
| --- | --- | --- |
| `cluster` (existing, `baf88382-...`) | everything the cluster's ExternalSecrets read | the ESO token; the admin token |
| `host-nodes` | `rke2/agent-token`, `headscale/preauth-key/cluster-node`, `attic/auth-token` | every cluster node |
| `host-hyena`, `host-chinchilla` | hyena: cloudflare token, adguard hash, ntfy users/tokens, headscale backup + OIDC keys, B2 bucket key. chinchilla: `attic/server-key` | that host |
| `host-personal` | `api/*`, `ssh/personal`, personal and family preauth keys, `ntfy/reader/token`, adb key | the workstations (Macs, falcon, axolotl, deck) |
| `host-<name>` | that host's Syncthing identity | that host |
| `bootstrap` | `hostkey/<host>` (the provisioned host keys), the `bws-backup` age *public* key | the admin token only |

A secret lives in exactly one project, so a value two tiers need (cloudflare token: cluster and hyena) is written twice by the same pulumi resource; one `pulumi up` keeps both in step.
Machine accounts: one per host class to start (`nodes`, `hyena`, `chinchilla`, `personal-mac`, `personal-linux`), splitting out per host where a host holds something its peers must not read.
Nodes share a blast radius today (one sops file readable by all node keys), so a shared `nodes` token is no regression.

### The one thing out of band: the host's token

The token cannot be derived from the ssh host key (Bitwarden issues it) and cannot be created by pulumi: `pulumi_bitwarden` (`pulumi/sdks/bitwarden`) has Project and Secret resources and no machine account or access token,
`bws` has only `config`, `project`, `secret`, `run`, and Bitwarden's quick start documents only the web app (creation checked 2026-10-16). So creating machine accounts and tokens is a manual step (docs/manual-steps.md), once per host class.

Delivery, all to `/var/lib/bws/token` (root, 0400; `bwsSecrets.tokenFile`):
- new install: nixos-anywhere `--extra-files` in `pulumi/millionaire/nixos.py`, replacing the current `passwords.age` extraction (the token comes from the admin's environment, not the repo);
- running host, no reinstall: `static/host-token.sh <host> <user@addr>` (the successor of `static/host-key.sh`, token on stdin);
- Hetzner golden image and cloud-burst workers: unchanged, cloud-init already delivers their three files (no sops key needed);
- rotation: a machine account can hold several tokens (expiry optional, none by default): issue the new one, deliver it, revoke the old one. Prefer a one-year expiry once delivery is a script.

Hardening not needed for stage 1: seal the token with `systemd-creds` (TPM2 where the board has one) instead of a plain file.

### Module: `modules/bws-secrets.nix` (in the repo)

`bwsSecrets.enable` (default off), `bwsSecrets.secrets.<name>.{key,project,path,owner,group,mode}` (defaults as sops-nix: `key` = the name, `path` = `/run/secrets/<name>`, `group` = the owner's group, `mode` 0400),
`tokenFile`, `cacheDir`, `hostKey`, `serverUrl`. A consumer changes `sops.secrets.x.key = "a/b"` to `bwsSecrets.secrets.x.key = "a/b"` (the BWS secret name instead of the yaml path) and keeps its `/run/secrets/x` path.
An assertion fails the build if a name is in both `sops.secrets` and `bwsSecrets.secrets`. Not mirrored from sops-nix: `sopsFile`, `format`, `restartUnits`, `neededForUsers`, templates (below).

`lib/bws-secrets.sh` (wrapped by `pkgs.writeShellApplication`, so shellcheck runs at build) has two modes:
- `restore`, run by an activation script (early boot and every switch, no network): decrypts `<cacheDir>/<name>.age` with the host ssh key and installs it. Never fails.
- `sync`, run by `bws-secrets.service` (after `network-online.target`, 30 s bound on the fetch, retried every 5 min on failure): one `bws secret list`, picks each secret by `key` (and `project` when set; a name that matches in two readable projects is an error),
  re-encrypts the cache to `<hostKey>.pub` (age reads ssh ed25519 keys directly), installs atomically (temp file in the target directory, chown, chmod, rename).
  Bitwarden or the token failing: it installs from the cache, says so on stderr and exits 1, so the unit shows failed while the host keeps working. A secret missing in Bitwarden fails only that secret.

Offline behaviour: a reboot during a Bitwarden outage gets the last fetched values from the cache, and `multi-user.target` waits at most the 30 s fetch bound. A host that never fetched successfully (new install, offline) has no cache and no secret: consumers that must have one
need `after`/`wants = ["bws-secrets.service"]` (stage 3: `rke2-*`, `tailscaled-autoconnect`). Not done in stage 1: a periodic refresh (rotations apply at the next switch or restart of the unit), per-secret `restartUnits`.

Gap to close before hyena (stage 4): `static/hyena.nix`, `static/ntfy.nix`, `static/headscale-backup.nix` use `sops.templates` (placeholders in AdGuardHome.yaml and env files). The module needs `templates.<n>.content` with `@name@` placeholders rendered by `sync`/`restore`.

### Macs, the Deck, home-manager

- The Deck is NixOS (`static/tailnet-personal.nix`): the same module, token in `/var/lib/bws/token`, project `host-personal`. It is the host that boots offline most often, which is what the cache is for.
- Macs: a nix-darwin variant of the module (stage 5). No systemd, so a `launchd.daemons.bws-secrets` (RunAtLoad, StartInterval 900) and the activation `restore`; `/run/secrets` already exists there (`modules/api-keys.nix` uses it today).
  The token is read from the System keychain instead of a file: the script gains `BWS_SECRETS_TOKEN_COMMAND` (`security find-generic-password -s bws-secrets -w /Library/Keychains/System.keychain`). The Mac's root of trust is that keychain item, replacing the age key (docs/manual-steps.md 12).
  Work-Mac caveat (memory, not re-checked): Kandji re-disables Remote Login; a launchd daemon needs none.
- No home-manager module: secrets are system-level with `owner = <user>`, as `modules/api-keys.nix` and `workstation-keys.nix` already do. home-manager consumers (`modules/opencode.nix`, `ntfy.nix`) read `osConfig.sops.secrets` today and switch to `osConfig.bwsSecrets.secrets`.
- Ad hoc use (`bws-get` in `modules/git.nix`, which decrypts the admin token with sops): reads the Mac's keychain item instead.

### Pulumi becomes write-only

Each `*_sops_write` command (`adguard_password_hash`, `cloudflare_token`, `headscale_backup_b2`, `ntfy`, `headscale_cluster_node_key`, `headscale_personal_key`, `headscale_family_key`, `attic`, `attic_auth`, `android_adb_key`) becomes a `Secret(key, value, project=...)`
(the helper in `pulumi/__main__.py` gains a `project_id` argument). The two reads of sops go away: `rke2_agent_token_read` (the cluster token becomes a pulumi-owned value; importing the live one first, regenerating it re-joins every node) and `passwords.age` in `nixos.py`.
A `pulumi up` is then the whole change: nothing to commit afterwards.

### What stays

Nothing in sops. The offline half of `bws-backup` is the exception in kind, not in place: its private age key (`age/bws-backup`) must never depend on Bitwarden, so it moves to offline media
(`bws-backup-restore-test` takes a key path); the public half goes to the `bootstrap` project.
Provisioned host keys (`hostkeys.yaml`) and Syncthing identities become BWS items (`hostkey/<host>`, `syncthing/<host>/{cert,key}`), written by pulumi and `syncthing-identity` (`bws secret create`). A host key is no longer a trust anchor,
only an ssh identity and the cache's age key. The `.sops.yaml` recipients, `&muffin`'s shared key and `static/host-key.sh` go with it.
The cluster's own BWS token (`external-secrets/bitwarden.nix`, `vals ref+sops` at render) becomes a render-time environment reference (`ref+envsubst://$BWS_ACCESS_TOKEN`, provider name not verified); the devshell takes the admin token from the keychain or `$BWS_ACCESS_TOKEN` instead of sops.

## Risks

- **Bitwarden availability at boot.** Mitigated by the cache for any host that has fetched once; a brand new host cannot start its consumers until the first fetch. Bitwarden loss entirely: the weekly `bws-backup` (docs/rebuild-from-git.md) is the way back, and its key must stay offline.
- **Token leakage is a full read** of that token's projects, and the token sits on disk. Per-tier projects bound it, tokens can expire, and `systemd-creds` sealing is the later hardening. Today's equivalent is a host key that decrypts its sops files, so the exposure moves rather than grows, except the admin token must never reach a host.
- **Bootstrapping a host** needs its token first (manual creation per class, scripted delivery). The first install of each class is the first real test of `--extra-files` plus the first fetch.
- **Cost** (bitwarden.com/products/secrets-manager, read 2026-10-16): Free is 3 projects, 3 machine accounts, 2 users, so the layout above needs Teams ($6 per user per month, 20 machine accounts, unlimited projects, $1 each beyond). Five to eight machine accounts fit.
- **Two copies of shared values** (cloudflare token in two projects): both written by one pulumi resource; a hand edit in the web app can diverge them.
- **canivete.sops.enable = false** (the last PR) removes `config.sops` everywhere and canivete's token-file wiring; every `sops.*` reference must be gone first, so it is the last step. cloud-worker already forces its own token file.

## Plan

1. This PR: module, `lib/bws-secrets.sh`, `tools/bws-secrets-test`, pilot: `attic-auth-token` (`static/k8s-node.nix`, behind `bwsSecrets.enable`, sops stays when off). Nothing deployed.
2. Seed and delivery: manual creation of the projects, machine accounts and tokens (docs/manual-steps.md); `tools/sops-to-bws` copies each live sops value into its project (idempotent, never regenerates); `static/host-token.sh`; `nixos.py` `--extra-files` token. Turn the pilot on for falcon, check `bws-secrets.service`, the file, and a reboot offline.
3. Nodes: `tailscale-authkey` (`static/tailnet.nix`), RKE2 token (`canivete.kubernetes.yaml.token-file`), attic keys (`static/attic-server.nix`), `after` ordering; `bwsSecrets.enable` default on for nodes. One node at a time, etcd quorum as in docs/node-standard.md.
4. hyena and chinchilla: module templates, then cloudflare, adguard, ntfy, headscale backup (drops the `hasInfix` gates).
5. Macs and the Deck: the darwin variant, keychain token, `api-keys`, `opencode`, `ntfy`, `workstation-keys`, `tailnet` login, `syncthing`, `git.nix` `bws-get`, echidna and gargoyle.
6. Pulumi write-only: replace the `*_sops_write` commands, the `k8s-token` and `passwords.age` reads, host keys and Syncthing identities as BWS items.
7. devshell and render: admin token without sops, B2 keys, `vals` reference in `external-secrets/bitwarden.nix`, `syncthing-identity`, restore tests, `bws-backup` key offline.
8. Delete `secrets/sops/`, `.sops.yaml`, the `sops-nix` input, `static/host-key.sh`; `canivete.sops.enable = false` with the token-file wiring set by us; drop the `typos` exclude and update docs/manual-steps.md, docs/node-standard.md, docs/rebuild-from-git.md, README 1.

## Validation of stage 1

- `tools/bws-secrets-test` (15 checks, fake `bws`, throwaway ssh key, no token, no network): install and byte-exact values, mode/owner/group, cache is age ciphertext, `restore` without bws or token, offline and rejected-token and missing-token fallbacks, no-cache failure, a secret missing in Bitwarden, an ambiguous name and the `project` fix, a missing target directory.
  Run: `nix shell nixpkgs#age nixpkgs#jq nixpkgs#openssh -c tools/bws-secrets-test` on falcon.
- falcon toplevel `drvPath` with the flag off equals main's; with the flag on (scratch `extendModules`) it evaluates, the sops secret is gone and the unit and activation script are present; the double-definition assertion fires.
- Not verified: the module on a running host, real Bitwarden calls (no token was used), `systemd` restart semantics of the oneshot with `Restart=on-failure` on a live switch, a reboot offline, vals' `envsubst` provider, Bitwarden pricing beyond the page read.
