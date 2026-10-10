# Pin files: pkgs/<name>/pin.json, pkgs/charts/<name>/pin.json,
# pkgs/images/<name>/pin.json. Read and bumped by tools/update. tools/pin-lint
# (pre-commit, deps-update) fails on hashes, revs or digestless images elsewhere.
#
# {
#   "version": "1.2.3",            required; tag, chart version or commit sha
#   "hash": "sha256-…",            required unless source.type = oci-tag
#   "digest": "sha256:…",          required for oci-tag
#   "hashes": {"vendorHash": …},   optional derived hashes
#   "source": {"type": …, …},      required; see `sources` below
#   "constraint": "<2.0",          optional; comma-separated version bounds
#   "hold": "reason",              optional; blocks updates
#   "follows": "charts/cilium"     optional; version must equal that pin's,
#                                  bumped (and rehashed) together with it
# }
{lib}: let
  # type -> { required params; optional params }
  sources = {
    github-release = {
      required = ["owner" "repo"];
      optional = ["tagPrefix"];
    };
    github-tag = {
      required = ["owner" "repo"];
      optional = ["tagPrefix" "tagPattern"];
    };
    git-commit = {
      required = ["owner" "repo" "branch"];
      optional = [];
    };
    helm-repo = {
      required = ["repo" "chart"];
      optional = [];
    };
    oci-tag = {
      required = ["repository"];
      optional = ["tagPattern" "track"];
    };
    url-template = {
      required = ["url"];
      optional = ["owner" "repo" "tagPrefix"];
    };
  };
  topKeys = ["version" "hash" "digest" "hashes" "source" "constraint" "hold" "follows"];

  validate = file: pin: let
    fail = msg: throw "pin ${toString file}: ${msg}";
    src = pin.source or (fail "missing source");
    type = src.type or (fail "missing source.type");
    spec = sources.${type} or (fail "unknown source.type '${type}'");
    isStr = k: lib.isString (pin.${k} or null);
    checks = [
      [(lib.isAttrs pin) "must be an object"]
      [(lib.subtractLists topKeys (lib.attrNames pin) == []) "unknown keys ${toString (lib.subtractLists topKeys (lib.attrNames pin))}"]
      [(isStr "version") "version must be a string"]
      [(type == "oci-tag" || isStr "hash") "hash must be a string"]
      [(type != "oci-tag" || isStr "digest") "digest must be a string"]
      [(lib.all (k: src ? ${k}) spec.required) "source.${type} needs ${toString spec.required}"]
      [(lib.subtractLists (["type"] ++ spec.required ++ spec.optional) (lib.attrNames src) == []) "unknown source keys"]
      [(lib.all lib.isString (lib.attrValues (pin.hashes or {}))) "hashes must be strings"]
      [(!(pin ? constraint) || isStr "constraint") "constraint must be a string"]
      [(!(pin ? hold) || isStr "hold") "hold must be a string"]
      [(!(pin ? follows) || isStr "follows") "follows must be a string"]
    ];
    failed = lib.findFirst (c: !(builtins.head c)) null checks;
  in
    if failed == null
    then pin
    else fail (lib.last failed);

  read = file: validate file (lib.importJSON file);

  tag = pin: (pin.source.tagPrefix or "") + pin.version;
  url = pin: builtins.replaceStrings ["{version}"] [pin.version] pin.source.url;

  # Fixed-output derivation for a pin. `kubelib` is nix-kube-generators' lib.
  fetch = {
    pkgs,
    kubelib,
  }: pin: let
    s = pin.source;
    github = ref: pkgs.fetchFromGitHub ({inherit (s) owner repo; inherit (pin) hash;} // ref);
  in
    {
      github-release = github {tag = tag pin;};
      github-tag = github {tag = tag pin;};
      git-commit = github {rev = pin.version;};
      url-template = pkgs.fetchurl {
        url = url pin;
        inherit (pin) hash;
      };
      helm-repo = (kubelib {inherit pkgs;}).downloadHelmChart {
        inherit (s) repo chart;
        inherit (pin) version;
        chartHash = pin.hash;
      };
    }
    .${
      s.type
    };

  # bjw-s app-template / most charts' image shape
  image = pin: {
    inherit (pin.source) repository;
    tag = pin.version;
    inherit (pin) digest;
  };
in {
  inherit sources validate read tag url fetch image;
}
