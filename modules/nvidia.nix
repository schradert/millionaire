{
  canivete.pkgs.allowUnfree = ["cuda_cccl" "cuda_cudart" "cuda_nvcc" "libcublas" "nvidia-x11" "nvidia-settings" "nvidia-persistenced"];
  nixos = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.nvidia.enable {
      hardware.nvidia = {
        modesetting.enable = true;
        open = true;
        package = config.boot.kernelPackages.nvidiaPackages.stable;
        powerManagement.enable = true;
      };
      nixpkgs.config.cudaSupport = true;
      services.xserver.videoDrivers = ["nvidia"];
    };
  };
}
