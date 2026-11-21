{
  pkgs,
  lib,
  userName ? null,
  config,
  ...
}:
let
  cfg = config.virtualisation.virtualbox.host;
  siteCfg = config.site.virtualbox;
  virtualbox =
    if config.security.wrappers ? VBoxHeadless then
      lib.removeSuffix "/libexec/virtualbox/VBoxHeadless" config.security.wrappers.VBoxHeadless.source
    else
      cfg.package;
  exportedEnv = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") siteCfg.environment
  );
  virtualboxLauncher = pkgs.runCommand "VirtualBox" { } ''
    test -x "${virtualbox}/bin/VirtualBox"
    mkdir -p "$out/bin"
    cat > "$out/bin/VirtualBox" <<'EOF'
    #!${pkgs.runtimeShell}
    ${exportedEnv}
    exec ${virtualbox}/bin/VirtualBox "$@"
    EOF
    sed -i 's/^    //' "$out/bin/VirtualBox"
    chmod +x "$out/bin/VirtualBox"
  '';
in
{
  options.site.virtualbox = {
    enable = lib.mkEnableOption "VirtualBox with the existing host integration";
    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Environment variables exported by the VirtualBox desktop launcher.";
    };
  };
  config = lib.mkIf siteCfg.enable {
    nixpkgs.config.allowUnfreePackages = [ "Oracle_VirtualBox_Extension_Pack" ];
    users.users.${userName}.extraGroups = [ "vboxusers" ];
    virtualisation.virtualbox.host.enable = true;
    environment.systemPackages = lib.optional (siteCfg.environment != { }) (
      pkgs.lib.hiPrio virtualboxLauncher
    );
    systemd.units."dev-vboxguest.device".text = ''
      [Unit]
      ConditionVirtualization=oracle
    '';
    boot.kernelParams = [ "kvm.enable_virt_at_load=0" ];
  };
}
