{ config, lib, pkgs, ... }:

{
  # must be deleted in the future
  boot.kernel.sysctl."kernel.unprivileged_userns_clone" = 1;

  # https://web.archive.org/web/20200724202300/https://forum.mxlinux.org/viewtopic.php?t=54591
  boot.kernel.sysctl."kernel.yama.ptrace_scope" = 1;

  security.chromiumSuidSandbox.enable = true;
  security.wrappers.${pkgs.chromium.sandbox.passthru.sandboxExecutableName}.permissions = "u+rwx,g+rx,o+rx";

  environment.etc =
    let
      text = ''
        whitelist   /run/wrappers/bin
        noblacklist /run/wrappers/bin
      '';
    in
    {
      "firejail/chromium-common.local" = { inherit text; };
      # "firejail/electron.local" = { inherit text; };
    };
}
