{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    localsend-discovery
  ];

  systemd.services."localsend-discovery" = {
    enable = true;
    after = [ "network.target" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      AmbientCapabilities = [ "CAP_NET_ADMIN" ];
      ExecStart = "${pkgs.localsend-discovery}/bin/localsend-discovery";
      DynamicUser = true;
      ProtectHome = "tmpfs";
      Restart = "on-failure";
      RestartSec = "30s";
      MemoryMax = "16M";
    };
  };
}
