{ config, pkgs, persistPath, ... }:

{
  me.allowedUnfreePkg = [
    "vscode"

    "vscode-extension-MS-python-vscode-pylance"
    "vscode-extension-ms-vscode-remote-remote-ssh"
    "vscode-extension-ms-vscode-cpptools"
  ];

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
      "editor.formatOnSave" = true;
      "editor.formatOnType" = false;
      "editor.wordWrap" = "on";
      "workbench.localHistory.enabled" = false;
      "telemetry.telemetryLevel" = "off";
      "telemetry.enableTelemetry" = false;
      "update.mode" = "none";
      "extensions.autoCheckUpdates" = false;
      "extensions.autoUpdate" = false;
    };
    extensions = (with pkgs.vscode-extensions; [
      esbenp.prettier-vscode
      jnoortheen.nix-ide
      ms-python.python
      # ms-vscode.makefile-tools
      # ms-vscode.cmake-tools
      ms-vscode.cpptools
      ms-azuretools.vscode-docker
      ms-python.vscode-pylance
      ms-vscode-remote.remote-ssh
    ]) ++ pkgs.vscode-utils.extensionsFromVscodeMarketplace [
      {
        # https://github.com/NixOS/nixpkgs/blob/a40b1a0c8296ffdfe90bd34ccfab19857586c005/pkgs/applications/editors/vscode/extensions/mktplcExtRefToFetchArgs.nix#L6C10-L6C179
        # https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers
        # https://${publisher}.gallery.vsassets.io/_apis/public/gallery/publisher/${publisher}/extension/${name}/${version}/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage
        # https://ms-vscode-remote.gallery.vsassets.io/_apis/public/gallery/publisher/ms-vscode-remote/extension/remote-containers/0.298.0/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage
        name = "remote-containers";
        publisher = "ms-vscode-remote";
        version = "0.298.0";
        sha256 = "19bylhfr1qzp79z9vflqrcrlr45x66w5pxgfvzkm51c9hzm3fr8i";
      }
    ];
  };

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [
      ".config/Code"
      ".cache/vscode-cpptools"
    ];
  };
}
