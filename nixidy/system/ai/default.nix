{
  imports = [
    ./nvidia-gpu-operator.nix
    # GPU-only workloads — disabled until a GPU node exists. No node has
    # nvidia.com/gpu capacity, so these sit Pending forever (scheduler:
    # "0/5 nodes match"). Re-enable when GPU hardware is added to the cluster.
    # ./ollama.nix
    # ./vllm.nix
    ./bifrost.nix
    ./toolhive.nix
    ./contextforge.nix
    ./librechat.nix
    ./promptfoo.nix
    ./openviking.nix
    # ./heretic.nix
    ./openclaw.nix
  ];
}
