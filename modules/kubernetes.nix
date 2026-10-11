# Cluster CLIs on workstations. `kubeconfig` fetches the RKE2 admin kubeconfig
# from sirver into ~/.kube/trdos (context `trdos`), pointed at sirver's tailnet
# IP; the API cert only names `sirver`, hence tls-server-name. ArgoCD logs in
# with Keycloak SSO (public client `argocd-cli`, nixidy/system/cicd/argocd.nix),
# Harbor with the `robot$push` account (Bitwarden `harbor/robot/secret`, pulumi).
{config, ...}: let
  inherit (config.canivete.meta) domain people;
  inherit ((import ../static/builders.nix).nodes.sirver) tailnet;
in {
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    kubeconfig = pkgs.writeShellApplication {
      name = "kubeconfig";
      runtimeInputs = with pkgs; [openssh yq-go];
      text = ''
        out=''${1:-$HOME/.kube/trdos}
        fetch() { ssh -o ConnectTimeout=5 "${people.me}@$1" 'sudo -n cat /etc/rancher/rke2/rke2.yaml'; }
        # Tailnet first, else the edge box (a port-forward to sirver)
        raw=$(fetch ${tailnet} || fetch 192.184.168.248)
        mkdir -p "$(dirname "$out")"
        umask 077
        yq '.clusters[0].cluster.server = "https://${tailnet}:6443"
          | .clusters[0].cluster."tls-server-name" = "sirver"
          | .clusters[0].name = "trdos" | .users[0].name = "trdos"
          | .contexts[0] = {"name": "trdos", "context": {"cluster": "trdos", "user": "trdos"}}
          | .current-context = "trdos"' <<<"$raw" >"$out"
        echo "wrote $out (context trdos)"
      '';
    };
    harbor-login = pkgs.writeShellScriptBin "harbor-login" ''
      bws-get harbor/robot/secret | ''${1:-docker} login harbor.${domain} --username 'robot$push' --password-stdin
    '';
  in {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = with pkgs; [argo-rollouts argocd cilium-cli harbor-login kubeconfig kubectl kubernetes-helm prometheus.cli];
      home.sessionVariables = {
        KUBECONFIG = "$HOME/.kube/config:$HOME/.kube/trdos";
        ARGOCD_OPTS = "--grpc-web";
      };
      home.shellAliases.argocd-login = "argocd login argocd.${domain} --sso";
      programs.k9s.enable = true;
    };
  };
}
