{ inputs, config, lib, pkgs, persistPath, ... }:

{
  # https://github.com/NixOS/nixpkgs/blob/a40b1a0c8296ffdfe90bd34ccfab19857586c005/pkgs/applications/editors/vscode/extensions/mktplcExtRefToFetchArgs.nix#L6C10-L6C179
  # https://marketplace.visualstudio.com/items?itemName=${publisher}.${name}
  # https://${publisher}.gallery.vsassets.io/_apis/public/gallery/publisher/${publisher}/extension/${name}/${version}/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage

  me.allowedUnfreePkg = with pkgs; [
    vscode

    vscode-extensions.ms-python.vscode-pylance
    # "vscode-extension-ms-vscode-remote-remote-ssh"
    vscode-extensions.ms-vscode.cpptools
  ];

  me.mimeApps.defApps.editor = "code.desktop";

  me.exitProcess = [
    "code"
  ];

  programs.vscode =
    let
      package = pkgs.vscode;
    in
    {
      inherit package;
      enable = true;
      userSettings = {
        "git.enabled" = true;
        "git.enableSmartCommit" = false;
        "git.enableCommitSigning" = false;
        "git.enableStatusBarSync" = false;
        "git.openRepositoryInParentFolders" = "always";
        "diffEditor.wordWrap" = "on";
        "editor.formatOnSave" = false;
        "editor.formatOnType" = false;
        "editor.wordWrap" = "on";
        "workbench.localHistory.enabled" = false;
        "telemetry.telemetryLevel" = "off";
        "telemetry.enableTelemetry" = false;
        "update.mode" = "none";
        "extensions.autoCheckUpdates" = false;
        "extensions.autoUpdate" = false;
        # "[json]" = {
        #   "editor.defaultFormatter" = "vscode.json-language-features";
        # };
        # "[jsonc]" = {
        #   "editor.defaultFormatter" = "vscode.json-language-features";
        # };
        # "[javascript]" = {
        #   "editor.defaultFormatter" = "vscode.typescript-language-features";
        # };
        # https://stackoverflow.com/a/74909302
        # https://github.com/microsoft/vscode/issues/113175
        "window.titleBarStyle" = "custom";
        # "files.associations" = {
        #   "cspell.json" = "jsonc";
        #   "v2ray.json" = "jsonc";
        #   "sing-box.json" = "jsonc";
        # };
        "remote.autoForwardPortsSource" = "hybrid";
        "editor.fontFamily" = "'JetBrainsMono Nerd Font', 'monospace', monospace";
        # "editor.tabSize" = 2;
      };
      extensions = (
        # with pkgs.vscode-extensions; [
        #   jnoortheen.nix-ide
        #   # ms-python.python
        #   # ms-vscode.makefile-tools
        #   # ms-vscode.cmake-tools
        #   # ms-vscode.cpptools
        #   # ms-azuretools.vscode-docker
        #   # ms-python.vscode-pylance
        #   # ms-vscode-remote.remote-ssh
        # ]
        [ ]
      ) ++ (
        with (inputs.nix-vscode-extensions.extensions.${pkgs.system}.forVSCodeVersion package.version).vscode-marketplace; [
          jnoortheen.nix-ide

          # esbenp.prettier-vscode

          ms-vscode-remote.remote-ssh
          ms-vscode-remote.remote-containers
          # ms-python.python
        ]
      );
    };

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [
      ".config/Code"
      ".cache/vscode-cpptools"
    ];
  };

  home.activation.fix-issue-244742-vscode = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    rm -rf "${persistPath}${config.home.homeDirectory}/.config/Code/GPUCache" || true
  '';
}
