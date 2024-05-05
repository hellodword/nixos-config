# { config, lib, pkgs, persistPath, ... }:

# let
#   DIRTY = "/usr/local/etc/dirty-chrome-sandbox";
# in
{
  # never do this, FIX IN THE FUTURE
  boot.kernel.sysctl."kernel.unprivileged_userns_clone" = 1;

  # https://ubuntu.com/blog/ubuntu-23-10-restricted-unprivileged-user-namespaces
  # > In a report from Google, 44% of the exploits they saw required unprivileged user namespaces as part of their exploit chain.
  # https://security.stackexchange.com/a/209533
  # https://lwn.net/Articles/673597/
  # https://github.com/input-output-hk/daedalus/issues/2025
  # https://github.com/canonical/lxd/issues/11920
  # https://github.com/brave/brave-browser/issues/3420#issuecomment-567222855

  # # https://web.archive.org/web/20200724202300/https://forum.mxlinux.org/viewtopic.php?t=54591

  # # chromium： 在 chromiumSuidSandbox.enable 后主要是修改一下权限为 755
  # # bitwarden - electron_27： 和 chromiumSuidSandbox 相似操作，然后在 overlays 里修改一下 CHROME_DEVEL_SANDBOX
  # # vscode： 不吃 CHROME_DEVEL_SANDBOX 环境变量，那么就干脆复制一份到 /nix/store 之外再用 overlays 修改 VSCODE_PATH，但 activationScripts 时 persistence 未必挂载好了，所以用绝对路径执行 activationScripts，用挂载后的路径修改 VSCODE_PATH

  # # 但是 setuid root 非常危险 🔴🔴🔴🔴🔴

  # boot.kernel.sysctl."kernel.yama.ptrace_scope" = 1;

  # security.chromiumSuidSandbox.enable = true;
  # security.wrappers = {
  #   ${pkgs.chromium.sandbox.passthru.sandboxExecutableName}.permissions = "u+rwx,g+rx,o+rx";
  #   "__${pkgs.electron_27.pname}-${lib.replaceStrings ["."] ["_"] pkgs.electron_27.version}-chrome-sandbox" =
  #     {
  #       setuid = true;
  #       owner = "root";
  #       group = "root";
  #       source = "${pkgs.electron_27.unwrapped}/libexec/electron/chrome-sandbox";
  #       permissions = "u+rwx,g+rx,o+rx";
  #     };
  # };

  # environment.etc =
  #   let
  #     text = ''
  #       whitelist   /run/wrappers/bin
  #       noblacklist /run/wrappers/bin
  #     '';
  #   in
  #   {
  #     "firejail/chromium-common.local" = { inherit text; };
  #     "firejail/electron.local" = { inherit text; };
  #   };

  # me.allowedUnfreePkg = [
  #   "vscode"
  # ];

  # system.activationScripts.dirty-vscode-chrome-sandbox.text = ''
  #   rm -rf "${persistPath}/${DIRTY}/__${pkgs.vscode.pname}"
  #   cp -r "${pkgs.vscode}" "${persistPath}/${DIRTY}/__${pkgs.vscode.pname}"
  #   chmod 4755 "${persistPath}/${DIRTY}/__${pkgs.vscode.pname}/lib/vscode/chrome-sandbox"
  # '';

  # environment.persistence = {
  #   "${persistPath}".directories = [
  #     DIRTY
  #   ];
  # };

}
