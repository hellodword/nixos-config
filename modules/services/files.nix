{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.files;
  tools = import ../../nix/files.nix { inherit pkgs; };
  hardening = import ../../lib/service-hardening.nix;
  home = config.users.users.${cfg.user}.home;
  state = "/var/lib/site-files";
  sambaSettings = {
    global = {
      "server role" = "standalone server";
      security = "user";
      "map to guest" = "Never";
      "server min protocol" = "SMB3_00";
      "server smb encrypt" = "required";
      "smb ports" = "445";
      interfaces = "lo";
      "bind interfaces only" = "yes";
      "disable netbios" = "yes";
      "load printers" = "no";
      "disable spoolss" = "yes";
      "printing" = "bsd";
      "printcap name" = "/dev/null";
      "dns proxy" = "no";
      "username map" = pkgs.writeText "site-files-smb-users" ''
        site-files-admin = admin
        site-files-user = user
      '';
      "passdb backend" = "tdbsam:${state}/samba/passdb.tdb";
      "private dir" = "${state}/samba";
      "state directory" = "${state}/samba";
      "cache directory" = "/run/site-files-smb/cache";
      "lock directory" = "/run/site-files-smb";
      "pid directory" = "/run/site-files-smb";
      "ncalrpc dir" = "/run/site-files-smb/ncalrpc";
      "logging" = "systemd";
      "log file" = "/run/site-files-smb/log.smbd";
      "follow symlinks" = "no";
      "wide links" = "no";
      "unix extensions" = "no";
      "create mask" = "0660";
      "directory mask" = "2770";
      "inherit permissions" = "yes";
      "vfs objects" = "streams_xattr";
    };
    files = {
      # %u is the authenticated Unix account, after the username map.
      path = "/srv/shares/%u";
      "valid users" = "site-files-admin site-files-user";
      "read only" = "no";
    };
  };
  sambaConfig = pkgs.concatText "site-files-smb.conf" [
    ((pkgs.formats.ini { }).generate "site-files-smb-global.conf" {
      inherit (sambaSettings) global;
    })
    ((pkgs.formats.ini { }).generate "site-files-smb-shares.conf" (
      removeAttrs sambaSettings [ "global" ]
    ))
  ];
  browserConfig = pkgs.writeText "site-files-browser.conf" ''
    [global]
      i: unix:660:site-files-web:/run/site-files-browser/copyparty.sock
      http-only
      no-crt
      rproxy: 1
      usernames
      logout: 720
      ses-db: ${state}/browser/sessions.db
      hist: ${state}/browser/history
      chmod-f: 660
      chmod-d: 2770
      xvol
      no-html
      no-mime
      no-readme
      no-logues
      no-thumb
      dav-auth
      daw

    [/]
      /srv/files
      accs:
        rwmd.: admin

    [/user]
      /srv/files/user
      accs:
        rwmd.: admin, user
  '';
  webConfig = pkgs.writeText "site-files-nginx.conf" ''
    worker_processes 1;
    pid /run/site-files-web/nginx.pid;
    error_log stderr warn;
    events { worker_connections 256; }
    http {
      access_log off;
      server_tokens off;
      client_max_body_size 0;
      client_body_temp_path /tmp/body;
      proxy_temp_path /tmp/proxy;
      ssl_protocols TLSv1.2 TLSv1.3;
      ssl_certificate /run/credentials/site-files-web.service/certificate;
      ssl_certificate_key /run/credentials/site-files-web.service/key;
      ssl_session_cache shared:files:1m;
      server {
        listen unix:/run/site-files-web/files.sock ssl;
        server_name _;
        location / {
          proxy_pass http://unix:/run/site-files-browser/copyparty.sock;
          proxy_set_header Host $http_host;
          proxy_set_header X-Forwarded-Host $http_host;
          proxy_set_header X-Forwarded-Proto https;
          # Socket bridges retain no client IP; the peer is this local proxy.
          proxy_set_header X-Forwarded-For 127.0.0.1;
          proxy_request_buffering off;
          proxy_buffering off;
          proxy_read_timeout 300s;
          add_header X-Content-Type-Options nosniff always;
        }
      }
      server {
        listen unix:/run/site-files-web/temporary.sock ssl;
        server_name _;
        location / {
          limit_except GET { deny all; }
          proxy_pass http://unix:/run/site-httpserver/socket/backend.sock;
          # Browser cookies are shared across ports on the same host.
          proxy_set_header Cookie "";
          proxy_set_header Authorization "";
          proxy_buffering off;
          proxy_intercept_errors on;
          error_page 502 504 =404 @idle;
        }
        location @idle { return 404; }
      }
    }
  '';
  isolated = hardening // {
    DynamicUser = false;
    PrivateNetwork = true;
    PrivatePIDs = true;
    Slice = "site-files.slice";
    RootDirectory = "/run/site-files-root";
    TemporaryFileSystem = [
      "/:ro"
      "/tmp:rw,nosuid,nodev,noexec,size=64M"
    ];
    BindReadOnlyPaths = [
      "/nix/store"
      "/etc/passwd"
      "/etc/group"
      "/etc/nsswitch.conf"
    ];
    UMask = "0007";
    Restart = "on-failure";
    RestartSec = "5s";
  };
  ingress = name: backend: destination: {
    description = "File service ${name} connection bridge";
    requires = [ "${backend}.service" ];
    after = [ "${backend}.service" ];
    partOf = [ "${backend}.service" ];
    serviceConfig = hardening // {
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --connections-max=64 ${destination}";
      Type = "notify";
      PrivateNetwork = true;
      SupplementaryGroups = [ "site-files-web" ];
      Slice = "site-files.slice";
    };
  };
in
{
  options.site.files = {
    enable = lib.mkEnableOption "private-network file services and temporary HTTPS sharing";
    user = lib.mkOption {
      type = lib.types.str;
      description = "Local owner of shared files and temporary shares.";
    };
    root = lib.mkOption {
      type = lib.types.str;
      default = "${home}/Downloads/dufs";
    };
    adminPasswordFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime file containing the admin password.";
    };
    userPasswordFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime file containing the restricted user account password.";
    };
    certificateConfigFile = lib.mkOption {
      type = lib.types.str;
      description = "Private runtime YAML document containing the files.certificateNames array.";
    };
    httpsPort = lib.mkOption {
      type = lib.types.port;
      default = 8443;
    };
    temporaryPort = lib.mkOption {
      type = lib.types.port;
      default = 8444;
    };
    temporary = {
      blockedNames = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "[^/\n\r]+");
        default = [
          ".ssh"
          ".gnupg"
          ".aws"
          ".kube"
          ".docker"
          ".git"
          ".env"
          ".env.*"
          ".netrc"
          ".npmrc"
          ".pypirc"
          ".git-credentials"
        ];
        description = "Blocked file/directory name globs at every level of a temporary share.";
      };
      blockedPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "/run/secrets"
          "/run/secrets-for-users"
          "/var/lib/sops-nix"
          "${state}/private"
          "${state}/samba"
          "${state}/accounts"
          "${state}/browser"
          "/etc/ssh"
          "${home}/.config/sops"
        ];
        description = "Absolute paths excluded from temporary sharing, including bind-mount aliases.";
      };
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.site.containers.enable;
        message = "site.files requires site.containers for gVisor temporary sharing.";
      }
      {
        assertion = lib.all (p: lib.hasPrefix "/" p && !lib.hasPrefix "/nix/store/" p) [
          cfg.adminPasswordFile
          cfg.userPasswordFile
          cfg.certificateConfigFile
        ];
        message = "File-service secrets must be runtime files outside the Nix store.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.root;
        message = "site.files.root must be an absolute path.";
      }
    ];
    users.groups = {
      site-files-admin.members = [ cfg.user ];
      site-files-share.members = [
        cfg.user
        "site-files-admin"
      ];
      site-files-web = { };
    };
    users.users = {
      site-files-admin = {
        isSystemUser = true;
        group = "site-files-admin";
      };
      site-files-user = {
        isSystemUser = true;
        group = "site-files-share";
      };
      site-files-browser = {
        isSystemUser = true;
        group = "site-files-web";
      };
      site-files-web = {
        isSystemUser = true;
        group = "site-files-web";
      };
    };
    environment.systemPackages = [
      (tools.certificate cfg.certificateConfigFile)
      (tools.httpserver {
        inherit (cfg) user;
        inherit home;
        hostname = config.networking.hostName;
        port = cfg.temporaryPort;
        inherit (config.site.storage) persistRoot;
        inherit (cfg.temporary) blockedNames blockedPaths;
      })
    ];
    virtualisation.docker.daemon.settings.runtimes.runsc-files = {
      path = "${pkgs.gvisor}/bin/runsc";
      runtimeArgs = [
        "--platform=systrap"
        "--host-uds=create"
      ];
    };
    systemd.tmpfiles.rules = [
      "d ${state} 0755 root root -"
      "d ${state}/private 0700 root root -"
      "d ${state}/samba 0700 root root -"
      "d ${state}/accounts 0700 root root -"
      # Account preparation uses group root to revoke sessions after a password change.
      "d ${state}/browser 0770 site-files-browser root -"
      "d /run/site-files-root 0755 root root -"
      "d /run/site-httpserver 2750 ${cfg.user} site-files-web -"
      "d /run/site-httpserver/socket 2750 ${cfg.user} site-files-web -"
    ];
    systemd.slices.site-files.sliceConfig = {
      MemoryMax = "1G";
      TasksMax = 256;
    };
    systemd.services = {
      site-files-directories = {
        description = "Prepare shared file directories and permissions";
        wantedBy = [ "multi-user.target" ];
        unitConfig.RequiresMountsFor = [ cfg.root ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0007";
        };
        script = ''
          ${pkgs.coreutils}/bin/install -d -m 2770 -o site-files-admin -g site-files-admin ${lib.escapeShellArg cfg.root}
          ${pkgs.coreutils}/bin/install -d -m 2770 -o site-files-user -g site-files-share ${lib.escapeShellArg "${cfg.root}/user"}
        '';
      };
      site-files-accounts = {
        description = "Load native file-service accounts";
        wantedBy = [ "multi-user.target" ];
        after = [ "sops-install-secrets.service" ];
        path = [
          pkgs.copyparty-min
          pkgs.samba
        ];
        serviceConfig = isolated // {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "no";
          RuntimeDirectory = "site-files-smb";
          RuntimeDirectoryMode = "0750";
          RuntimeDirectoryPreserve = true;
          BindPaths = [
            "${state}/samba"
            "${state}/accounts"
            "${state}/browser"
            "/run/site-files-smb"
          ];
          LoadCredential = [
            "admin:${cfg.adminPasswordFile}"
            "user:${cfg.userPasswordFile}"
          ];
          Environment = "XDG_CONFIG_HOME=/tmp";
          ExecStart = "${pkgs.python3}/bin/python3 ${../../scripts/files/accounts.py} ${sambaConfig} ${state}";
        };
      };
      site-files-browser = {
        description = "Authenticated file browser and WebDAV";
        wantedBy = [ "multi-user.target" ];
        requires = [
          "site-files-directories.service"
          "site-files-accounts.service"
        ];
        after = [
          "site-files-directories.service"
          "site-files-accounts.service"
        ];
        partOf = [ "site-files-accounts.service" ];
        serviceConfig = isolated // {
          User = "site-files-browser";
          Group = "site-files-web";
          SupplementaryGroups = [
            "site-files-admin"
            "site-files-share"
          ];
          # Copyparty creates directories with the shared parent's setgid bit.
          RestrictSUIDSGID = false;
          RuntimeDirectory = "site-files-browser";
          RuntimeDirectoryMode = "0750";
          RuntimeDirectoryPreserve = true;
          BindPaths = [
            "${cfg.root}:/srv/files"
            "${state}/browser"
            "/run/site-files-browser"
          ];
          LoadCredential = [ "accounts:${state}/accounts/copyparty.conf" ];
          Environment = "XDG_CONFIG_HOME=${state}/browser";
          ExecStart = "${pkgs.tini}/bin/tini -e 143 -- ${pkgs.copyparty-min}/bin/copyparty -c ${browserConfig} -c /run/credentials/site-files-browser.service/accounts";
        };
      };
      site-files-web = {
        description = "File-service HTTPS endpoints";
        wantedBy = [ "multi-user.target" ];
        wants = [ "site-files-browser.service" ];
        after = [ "site-files-browser.service" ];
        unitConfig.ConditionPathExists = "${state}/server.crt";
        serviceConfig = isolated // {
          User = "site-files-web";
          Group = "site-files-web";
          RuntimeDirectory = "site-files-web";
          RuntimeDirectoryMode = "0750";
          BindPaths = [ "/run/site-files-web" ];
          BindReadOnlyPaths = isolated.BindReadOnlyPaths ++ [
            "/run/site-files-browser"
            "/run/site-httpserver/socket"
          ];
          LoadCredential = [
            "certificate:${state}/server.crt"
            "key:${state}/private/server.key"
          ];
          ExecStart = "${pkgs.nginx}/bin/nginx -e stderr -c ${webConfig} -g 'daemon off;'";
        };
      };
      site-files-smb = {
        description = "Encrypted SMB file shares";
        wantedBy = [ "multi-user.target" ];
        requires = [
          "site-files-directories.service"
          "site-files-accounts.service"
        ];
        after = [
          "site-files-directories.service"
          "site-files-accounts.service"
        ];
        partOf = [ "site-files-accounts.service" ];
        serviceConfig = isolated // {
          # smbd authenticates locally and changes to each account's Unix identity.
          # Directory creation preserves the shared parent's setgid bit.
          RestrictSUIDSGID = false;
          RestrictAddressFamilies = isolated.RestrictAddressFamilies ++ [ "AF_NETLINK" ];
          CapabilityBoundingSet = [
            "CAP_SETUID"
            "CAP_SETGID"
            "CAP_DAC_OVERRIDE"
            "CAP_CHOWN"
            "CAP_FOWNER"
            "CAP_NET_BIND_SERVICE"
          ];
          BindPaths = [
            "${cfg.root}:/srv/shares/site-files-admin"
            "${cfg.root}/user:/srv/shares/site-files-user"
            "${state}/samba"
            "/run/site-files-smb"
          ];
          ExecStart = "${pkgs.samba}/sbin/smbd --foreground --debug-stdout --no-process-group --configfile=${sambaConfig}";
          NotifyAccess = "all";
          Type = "notify";
        };
      };
      site-files-https = ingress "HTTPS" "site-files-web" "/run/site-files-web/files.sock";
      site-files-temporary =
        ingress "temporary HTTPS" "site-files-web"
          "/run/site-files-web/temporary.sock";
      site-files-smb-proxy = (ingress "SMB" "site-files-smb" "127.0.0.1:445") // {
        unitConfig.JoinsNamespaceOf = [ "site-files-smb.service" ];
      };
    };
    systemd.sockets =
      lib.mapAttrs
        (_: port: {
          wantedBy = [ "sockets.target" ];
          listenStreams = [ (toString port) ];
          socketConfig = {
            BindIPv6Only = "both";
            Backlog = 64;
          };
        })
        {
          site-files-https = cfg.httpsPort;
          site-files-temporary = cfg.temporaryPort;
          site-files-smb-proxy = 445;
        };
  };
}
