# Who gets their own music scrobble history, and the names derived from it (docs/media-stack.md,
# "Music scrobbling"). The set is every declared Keycloak user in the `family` or `admin` group
# (`keycloakUsers`, docs/invite.md) plus the `e2e` fixture, so inviting someone also gives them a
# private Maloja, a multi-scrobbler route and a linked Navidrome account without another edit.
#
# Maloja has no accounts, so "per user" means one Maloja data directory per user: the owner keeps the
# original one at /mljdata (and the Service/host `maloja`), everyone else gets a sidecar of the same
# pod with its own directory, port, Service and host (`maloja-<user>`).
{config, ...}: let
  inherit (config.canivete.meta) domain people;
in {
  nixidy = {
    config,
    lib,
    ...
  }: let
    declared = lib.concatMap (u: let
      d = u.spec.definition;
    in
      lib.optional (lib.any (g: lib.elem g (d.groups or [])) ["family" "admin"]) d.username)
    (lib.attrValues config.applications.keycloak.resources.keycloakUsers);
    # Non-owner users get consecutive ports after Maloja's own, in name order.
    others = lib.sort (a: b: a < b) (lib.unique (lib.filter (u: u != people.me) (declared ++ ["e2e"])));
    isMe = u: u == people.me;
    base = 42010;
  in {
    _module.args.scrobble = rec {
      # The owner first, then the rest by name.
      users = [people.me] ++ others;
      inherit others isMe;
      port = u:
        if isMe u
        then base
        else base + 1 + lib.lists.findFirstIndex (x: x == u) null others;
      service = u:
        if isMe u
        then "maloja"
        else "maloja-${u}";
      url = u: "http://${service u}.media.svc.cluster.local:${toString (port u)}";
      host = u: "${service u}.${domain}";
      dataDir = u:
        if isMe u
        then "/mljdata"
        else "/mljdata/users/${u}";
      # Generated once in-cluster, key `token` in each: what Navidrome presents to multi-scrobbler
      # (the user's "ListenBrainz token"), and what multi-scrobbler presents to the user's Maloja.
      ingressSecret = u: "scrobble-lz-${u}";
      malojaSecret = u: "scrobble-maloja-${u}";
      # Names inside multi-scrobbler. The owner keeps the ids it had before this was per user.
      sourceId = kind: u:
        if isMe u
        then kind
        else "${kind}-${u}";
    };
  };
}
