# Inviting someone

Keycloak is the only account system. Everyone signs in to Jellyfin, Seerr, Immich, Ombi and the rest as their own Keycloak user; the apps create their own accounts on first sign-in. There are no per-app invites, passwords or shared logins (Wizarr is not deployed: it creates local Jellyfin accounts with a password the invitee picks).

## Invite a person

Add one entry to `nixidy/apps/identity/keycloak-operator.nix` and merge:

```nix
keycloakUsers.alice.spec = {
  realmRef.name = "default";
  definition = {
    username = "alice";
    email = "alice@example.com";
    firstName = "Alice";
    lastName = "Example";
    enabled = true;
    groups = ["family"];
  };
};
```

Within ten minutes of the sync, the `keycloak-invite` CronJob sends Alice Keycloak's "Update Your Account" email (set a password, verify the email; link valid for 7 days). The link goes to `https://keycloak.trdos.me`, which needs the tailnet or the home network. After setting a password she signs in to each app with "Sign in with Keycloak" (Jellyfin's login page has the button; the apps behind oauth2-proxy redirect to Keycloak by themselves). Her role in each app comes from her groups: `family` is a normal user, `admin` (add it to `groups`) is an administrator. Admin stays rare.

## Details

- The job (`app-bootstrap keycloak-invite`) emails every enabled `family` member who has an email, no password yet and no key in the ConfigMap `keycloak-invites` (namespace `identity`, one key per Keycloak user id), then writes the key. People who already have a password are skipped.
- Resend: `kubectl -n identity patch configmap keycloak-invites --type json -p '[{"op":"remove","path":"/data/<user id>"}]'`, or the person uses "Forgot password" on the Keycloak login page (enabled in the realm).
- Remove someone: delete the entry and merge; the operator deletes the Keycloak user. Their per-app accounts stay until removed in each app.
- Notes and calendar: a `family` or `admin` member also gets a Baïkal DAV user with an `org` calendar and a generated password (Bitwarden `baikal/<username>/password`). Their own Syncthing hub and org-bridge are one more entry in `modules/syncthing.nix` (docs/productivity.md, "Adding a person").
- Music: the same entry gives the person their own Maloja (`https://maloja-<username>.trdos.me`, for them and admins), their own multi-scrobbler routes and a linked Navidrome account, so their Jellyfin and Navidrome plays are scrobbled to their own history (docs/media-stack.md, "Music scrobbling per user"). Jellyfin plays are matched by Jellyfin username, which must equal the Keycloak username.
- Mail leaves through Stalwart's relay (Proton). Check `kubectl -n identity logs job/<keycloak-invite-...>` for `sent ... to <address>`.
