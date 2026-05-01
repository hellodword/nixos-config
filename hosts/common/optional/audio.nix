{
  lib,
  pkgs,
  persistPath,
  userName,
  ...
}:

{
  # https://github.com/balsoft/nixos-config/blob/a0f28267b8e3b822ce8dc673b13a1862ee49e0cb/profiles/sound.nix#L4
  # https://github.com/bqv/rc/blob/7fb53a24e416142e1909e87d19727b6ef4f43236/profiles/sound/pipewire.nix
  # https://github.com/Aylur/dotfiles/blob/a1f4795aae6aeff3eb3c332c39ca7094f812b88e/nixos/audio.nix

  # pipewire does not require audio group

  services.pulseaudio.enable = lib.mkForce false;

  security.rtkit.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
    wireplumber.enable = true;
  };

  environment.systemPackages = with pkgs; [
    # # 均衡器
    # easyeffects

    # # 接线盒 手动调整音频输入输出
    # # make connections in the graph
    # helvum
    # qpwgraph

    # # To configure Card Profiles, default devices, ports and other settings, we recommend to use pavucontrol.
    pavucontrol
  ];

  home-manager.users."${userName}".home.persistence = {
    "${persistPath}".directories = [ ".local/state/wireplumber" ];
  };
}
