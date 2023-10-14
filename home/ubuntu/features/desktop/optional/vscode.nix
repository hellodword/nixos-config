{ config, lib, pkgs, persistPath, ... }:

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
      "editor.formatOnSave" = true;
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
      {
        # https://ms-vscode-remote.gallery.vsassets.io/_apis/public/gallery/publisher/ms-vscode-remote/extension/remote-ssh/0.107.2023100615/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage
        # https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh
        name = "remote-ssh";
        publisher = "ms-vscode-remote";
        version = "0.107.2023100615";
        sha256 = "1q73mznnq8385d0g0gvn3iq8j16zrin84czz0fzc8w99409mq5x5";
      }
      {
        # https://ms-vscode-remote.gallery.vsassets.io/_apis/public/gallery/publisher/ms-vscode-remote/extension/remote-containers/0.318.0/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage
        # https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers
        name = "remote-containers";
        publisher = "ms-vscode-remote";
        version = "0.318.0";
        sha256 = "1mp507c7clzbcr0iyjx0w9inajy8k344r367q3vzyw9ic3p6j4ws";
      }
      {
        # https://ms-python.gallery.vsassets.io/_apis/public/gallery/publisher/ms-python/extension/python/2023.19.12861011/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage
        # https://github.com/microsoft/vscode-python/releases
        name = "python";
        publisher = "ms-python";
        version = "2023.19.12861011";
        sha256 = "0ki20jr75ajygmjjwpb4p9d6pq96cfkyy0s245c1khg2kivsd9lv";
      }
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
