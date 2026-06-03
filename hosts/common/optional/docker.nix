{
  pkgs,
  lib,
  persistPath,
  userName,
  ...
}:

{
  environment.systemPackages = with pkgs; [ dive ];

  users.users."${userName}".extraGroups = [ "docker" ];

  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
      flags = [ ];
    };
    daemon.settings = {
      # fixed-cidr-v6 = "fd00::/80";
      # ipv6 = true;
      runtimes.runsc = {
        path = "${pkgs.gvisor}/bin/runsc";
        "runtimeArgs" = [
          "--platform=systrap"
        ];
      };
    };
    # extraOptions = ''
    #   --default-ulimit nofile=104857600:104857600
    # '';
  };

  # wait for persistence mounts
  systemd.services.docker.after = [ "local-fs.target" ];

  environment.persistence = {
    "${persistPath}".directories = [
      "/var/lib/docker"
    ];
  };

  # security.pam.loginLimits = [
  #   {
  #     domain = "@docker";
  #     item = "nofile";
  #     type = "soft";
  #     value = "unlimited";
  #   }
  #   {
  #     domain = "@docker";
  #     item = "nofile";
  #     type = "hard";
  #     value = "unlimited";
  #   }
  # ];

  /*
    LimitNOFILE=infinity
    LimitNOFILESoft=infinity
  */
  systemd.services."docker".serviceConfig.LimitNOFILE = lib.mkForce "infinity";
  systemd.services."docker".serviceConfig.LimitNOFILESoft = lib.mkForce "infinity";
  # systemd.services."docker".serviceConfig.LimitSIGPENDING = lib.mkForce "255470";
  # systemd.services."docker".serviceConfig.LimitSIGPENDINGSoft = lib.mkForce "255470";

  # boot.kernel.sysctl."fs.epoll.max_user_watches" = 14558720;
  # boot.kernel.sysctl."fs.fanotify.max_user_marks" = 529826;
}
