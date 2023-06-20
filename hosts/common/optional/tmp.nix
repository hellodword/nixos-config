{
  # https://lantian.pub/article/modify-computer/nixos-impermanence.lantian/#%E7%A7%BB%E5%8A%A8-nix-daemon-%E7%9A%84%E4%B8%B4%E6%97%B6%E6%96%87%E4%BB%B6%E5%A4%B9
  boot.tmp.useTmpfs = true; # boot.tmpOnTmpfs = true;
  boot.tmp.tmpfsSize = "80%"; # boot.tmpOnTmpfsSize = "80%";
  environment.variables.NIX_REMOTE = "daemon";

  systemd.services.nix-daemon = {
    environment = {
      # 指定临时文件的位置
      TMPDIR = "/var/cache/nix";
    };
    serviceConfig = {
      # 在 Nix Daemon 启动时自动创建 /var/cache/nix
      CacheDirectory = "nix";
    };
  };
}
