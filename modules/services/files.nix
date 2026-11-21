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
  webConfig = pkgs.writeText "site-files-haproxy.conf" ''
    global
      nbthread 1
      maxconn 256
      log /run/systemd/journal/dev-log len 65535 format local local0
      ssl-default-bind-options ssl-min-ver TLSv1.2

    defaults
      mode http
      log global
      timeout connect 5s
      timeout client 300s
      timeout server 300s
      timeout http-request 60s
      timeout http-keep-alive 60s
      retries 0

    crt-store files
      load crt /run/credentials/site-files-web.service/certificate key /run/credentials/site-files-web.service/key alias server

    frontend transport
      mode tcp
      no log
      bind /run/site-files-web/files.sock mode 660 accept-proxy
      bind /run/site-files-web/temporary.sock mode 660 accept-proxy
      tcp-request inspect-delay 5s
      tcp-request content accept if { req.ssl_hello_type 1 }
      tcp-request content accept if HTTP
      use_backend temporary_tls if { req.ssl_hello_type 1 } { dst_port ${toString cfg.temporaryPort} }
      use_backend files_tls if { req.ssl_hello_type 1 }
      default_backend plaintext

    backend files_tls
      mode tcp
      server files /run/site-files-web/files-tls.sock send-proxy-v2

    backend temporary_tls
      mode tcp
      server temporary /run/site-files-web/temporary-tls.sock send-proxy-v2

    backend plaintext
      mode tcp
      server redirect /run/site-files-web/redirect.sock send-proxy-v2

    frontend redirect
      option httplog
      bind /run/site-files-web/redirect.sock mode 660 accept-proxy
      http-request deny deny_status 405 unless METH_GET
      acl valid_host req.hdr(Host) -m reg ^([A-Za-z0-9.-]+|\[[A-Fa-f0-9:]+\])(:[0-9]+)?$
      http-request deny deny_status 400 unless valid_host
      http-request redirect location https://%[req.hdr(Host),regsub(:[0-9]+$,\"\")]:%[dst_port]%[url] code 308

    frontend https
      log-format "%{+json,+utf8}o %(time)trg %(port)fp %(client)ci %(method)HM %(host)[var(txn.host)] %(url)[var(txn.url)] %(path)[var(txn.path)] %(request_headers)[var(txn.request_headers)] %(request_body)[var(txn.request_body)] %(status)ST %(response_headers)[var(txn.response_headers)] %(request_bytes)U %(response_bytes)B %(duration_ms)Ta %(upstream_status)[var(txn.upstream_status)] %(upstream_ms)Tr %(termination)ts"
      bind /run/site-files-web/files-tls.sock mode 660 accept-proxy ssl crt @files/server verify required ca-file /run/credentials/site-files-web.service/client-ca
      bind /run/site-files-web/temporary-tls.sock mode 660 accept-proxy ssl crt @files/server verify none
      acl temporary dst_port ${toString cfg.temporaryPort}
      acl device_present ssl_c_used
      acl device_verified ssl_c_verify 0
      acl device_allowed ssl_c_der,sha2(256),hex -m str -f /run/credentials/site-files-web.service/devices
      acl text_body req.hdr(Content-Type),field(1,;),lower -m reg ^text/ ^application/(.*[+])?(json|xml)$ ^application/(x-www-form-urlencoded|javascript|x-javascript|graphql|yaml|x-yaml|toml|x-ndjson)$
      acl encoded_body req.hdr(Content-Encoding) -m found
      acl plain_body req.hdr(Content-Encoding) -i identity

      # Capture the client's headers before adding forwarding metadata.
      http-request set-var(txn.host) req.hdr(Host)
      http-request set-var(txn.url) url
      http-request set-var(txn.path) path,url_dec
      http-request set-var(txn.request_headers) req.hdrs
      # Wait for at most this prefix (or end of body), then stream the remainder.
      http-request wait-for-body time 60s at-least 4096 if text_body !encoded_body or text_body plain_body
      http-request set-var(txn.request_body) req.body,bytes(0,4096) if text_body !encoded_body or text_body plain_body
      http-request deny deny_status 403 if !temporary !device_present
      http-request deny deny_status 403 if !temporary !device_verified
      http-request deny deny_status 403 if !temporary !device_allowed
      http-request set-header X-Forwarded-For %[src]
      http-request set-header X-Forwarded-Host %[req.hdr(Host)]
      http-request set-header X-Forwarded-Proto https

      http-response set-var(txn.upstream_status) status
      http-after-response set-header X-Content-Type-Options nosniff if !temporary
      http-after-response set-var(txn.response_headers) res.hdrs
      use_backend temporary if temporary
      default_backend browser

    backend browser
      server browser /run/site-files-browser/copyparty.sock

    backend temporary
      # Browser cookies are shared across ports on the same host.
      http-request set-var(txn.share_session) req.cook(site_share)
      http-request del-header Cookie
      http-request del-header Authorization
      http-request set-header X-Share-Session %[var(txn.share_session)]
      http-error status 502 content-type text/plain string "Not Found"
      http-error status 503 content-type text/plain string "Not Found"
      http-error status 504 content-type text/plain string "Not Found"
      http-after-response set-status 404 if { status 502 503 504 }
      server temporary /run/site-httpserver/socket/backend.sock
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
  ingress =
    {
      name,
      backend,
      destination,
      proxyProtocol ? false,
    }:
    {
      description = "File service ${name} connection bridge";
      requires = [ "${backend}.service" ];
      after = [ "${backend}.service" ];
      partOf = [ "${backend}.service" ];
      serviceConfig = hardening // {
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --connections-max=64 ${lib.optionalString proxyProtocol "--proxy-protocol=v1 "}${destination}";
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
      tools.client
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
        requires = [ "site-files-client-authority.service" ];
        after = [
          "site-files-browser.service"
          "site-files-client-authority.service"
        ];
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
            "/run/systemd/journal/dev-log"
          ];
          LoadCredential = [
            "certificate:${state}/server.crt"
            "key:${state}/private/server.key"
            "client-ca:${state}/private/clients/ca.crt"
            "devices:${state}/private/clients/authorized"
          ];
          ExecStart = "${pkgs.tini}/bin/tini -e 143 -- ${pkgs.haproxy}/sbin/haproxy -db -f ${webConfig}";
        };
      };
      site-files-client-authority = {
        description = "Prepare file-service device certificate authority";
        serviceConfig = hardening // {
          DynamicUser = false;
          PrivateNetwork = true;
          ReadWritePaths = [ "${state}/private" ];
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
          ExecStart = "${tools.client}/bin/site-files-client init";
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
      site-files-https = ingress {
        name = "HTTPS";
        backend = "site-files-web";
        destination = "/run/site-files-web/files.sock";
        proxyProtocol = true;
      };
      site-files-temporary = ingress {
        name = "temporary HTTPS";
        backend = "site-files-web";
        destination = "/run/site-files-web/temporary.sock";
        proxyProtocol = true;
      };
      site-files-smb-proxy =
        (ingress {
          name = "SMB";
          backend = "site-files-smb";
          destination = "127.0.0.1:445";
        })
        // {
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
