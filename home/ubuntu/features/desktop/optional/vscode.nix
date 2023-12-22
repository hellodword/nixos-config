{ inputs, config, lib, pkgs, persistPath, ... }:

{
  # https://github.com/NixOS/nixpkgs/blob/a40b1a0c8296ffdfe90bd34ccfab19857586c005/pkgs/applications/editors/vscode/extensions/mktplcExtRefToFetchArgs.nix#L6C10-L6C179
  # https://marketplace.visualstudio.com/items?itemName=${publisher}.${name}
  # https://${publisher}.gallery.vsassets.io/_apis/public/gallery/publisher/${publisher}/extension/${name}/${version}/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage

  me.allowedUnfreePkg = [
    "vscode"

    "vscode-extension-MS-python-vscode-pylance"
    # "vscode-extension-ms-vscode-remote-remote-ssh"
    "vscode-extension-ms-vscode-cpptools"
  ];

  me.mimeApps.defApps.editor = "code.desktop";

  programs.vscode = {
    enable = true;
    package = pkgs.vscode;
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
      "[json]" = {
        "editor.defaultFormatter" = "vscode.json-language-features";
      };
      "[jsonc]" = {
        "editor.defaultFormatter" = "vscode.json-language-features";
      };
      "[javascript]" = {
        "editor.defaultFormatter" = "vscode.typescript-language-features";
      };
      # https://stackoverflow.com/a/74909302
      # https://github.com/microsoft/vscode/issues/113175
      "window.titleBarStyle" = "custom";
      "files.associations" = {
        "cspell.json" = "jsonc";
        "v2ray.json" = "jsonc";
      };
      "remote.autoForwardPortsSource" = "hybrid";
    };
    extensions = (with pkgs.vscode-extensions; [
      esbenp.prettier-vscode
      jnoortheen.nix-ide
      # ms-python.python
      # ms-vscode.makefile-tools
      # ms-vscode.cmake-tools
      ms-vscode.cpptools
      ms-azuretools.vscode-docker
      ms-python.vscode-pylance
      # ms-vscode-remote.remote-ssh
    ]) ++ pkgs.vscode-utils.extensionsFromVscodeMarketplace [
      inputs.nix-vscode-ext.vscode-extensions.ms-vscode-remote.remote-ssh
      inputs.nix-vscode-ext.vscode-extensions.ms-vscode-remote.remote-containers
      inputs.nix-vscode-ext.vscode-extensions.ms-python.python
    ];
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
