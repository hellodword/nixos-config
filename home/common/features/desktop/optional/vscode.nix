{
  config,
  lib,
  pkgs,
  persistPath,
  ...
}:

{
  # https://github.com/NixOS/nixpkgs/blob/a40b1a0c8296ffdfe90bd34ccfab19857586c005/pkgs/applications/editors/vscode/extensions/mktplcExtRefToFetchArgs.nix#L6C10-L6C179
  # https://marketplace.visualstudio.com/items?itemName=${publisher}.${name}
  # https://${publisher}.gallery.vsassets.io/_apis/public/gallery/publisher/${publisher}/extension/${name}/${version}/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage

  me.allowedUnfreePkg = [ pkgs.vscode ] ++ config.programs.vscode.profiles.default.extensions;

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
      profiles.default.keybindings = [
        {
          # 让 ctrl+q 只关闭当前实例，而不是无确认地关闭所有实例
          key = "ctrl+q";
          command = "workbench.action.closeWindow";
        }

        # fix the conflict of terminal paste
        {
          key = "ctrl+shift+v";
          command = "-markdown-preview-enhanced.openPreview";
        }
        {
          key = "ctrl+shift+v";
          command = "-markdown.togglePreview";
        }
        {
          key = "ctrl+shift+v";
          command = "-notebook.cell.pasteAbove";
        }
      ];
      profiles.default.userSettings = {
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
        "extensions.autoUpdate" = "off";
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

        "extensions.ignoreRecommendations" = true;

        "github.gitAuthentication" = false;
        "github.branchProtection" = false;
        "github.showAvatar" = false;
        "files.eol" = "\n";

        # disable copilot
        "chat.agent.enabled" = false;
        # "chat.mcp.enabled" = false;
        "chat.edits2.enabled" = false;
        "chat.commandCenter.enabled" = false;
        "chat.mcp.discovery.enabled" = {
          "claude-desktop" = false;
          "windsurf" = false;
          "cursor-global" = false;
          "cursor-workspace" = false;
        };
        "chat.extensionTools.enabled" = false;
        "chat.implicitContext.enabled" = {
          "panel" = "never";
          "editing-session" = "never";
        };
        "chat.detectParticipant.enabled" = false;
        "chat.mcp.access" = "none";
        "chat.disableAIFeatures" = true;
      };
      profiles.default.extensions = with pkgs.vscode-extensions; [
        jnoortheen.nix-ide
        # ms-python.python
        # ms-vscode.makefile-tools
        # ms-vscode.cmake-tools
        # ms-vscode.cpptools
        # ms-azuretools.vscode-docker
        # ms-python.vscode-pylance
        # ms-vscode-remote.remote-ssh
        ms-vscode-remote.remote-containers
      ];
    };

  home.persistence = {
    "${persistPath}".directories = [
      ".config/Code"
      ".cache/vscode-cpptools"
      ".vscode"
      ".vscode-shared"
    ];
  };

  home.activation.fix-issue-244742-vscode = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    rm -rf "${persistPath}${config.home.homeDirectory}/.config/Code/GPUCache" || true
  '';
}
