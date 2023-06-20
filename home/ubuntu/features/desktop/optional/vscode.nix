{ config, pkgs, persistPath, ... }:

{
  allowedUnfreePkg = [
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
      dart-code.dart-code
      dart-code.flutter
      esbenp.prettier-vscode
      golang.go
      jnoortheen.nix-ide
      ms-python.python
      ms-vscode.makefile-tools
      ms-vscode.cmake-tools
      ms-vscode.cpptools
      ms-azuretools.vscode-docker
      ms-python.vscode-pylance
      ms-vscode-remote.remote-ssh
    ]) ++ pkgs.vscode-utils.extensionsFromVscodeMarketplace [
      {
        name = "remote-containers";
        publisher = "ms-vscode-remote";
        version = "0.295.0";
        sha256 = "1bzyag89qvd92mwagw3l3qm5383nbf06x65di5yw3mw67dk5s5g4";
      }
    ];
  };

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [
      ".config/Code"
    ];
  };
}
