{
  persistRoot,
  stateDirectory ? null,
}:
{
  NoNewPrivileges = true;
  CapabilityBoundingSet = "";
  ProtectSystem = "strict";
  TemporaryFileSystem = "%h:ro";
  BindPaths = if stateDirectory == null then [ ] else [ "%h/${stateDirectory}" ];
  BindReadOnlyPaths = [ "-%h/.Xauthority" ];
  InaccessiblePaths = [ persistRoot ];
  PrivateDevices = true;
  ProtectKernelTunables = true;
  ProtectKernelModules = true;
  ProtectKernelLogs = true;
  ProtectControlGroups = true;
  RestrictNamespaces = true;
  RestrictRealtime = true;
  RestrictSUIDSGID = true;
  LockPersonality = true;
  SystemCallArchitectures = "native";
  SystemCallFilter = [ "@system-service" ];
  RestrictAddressFamilies = [ "AF_UNIX" ];
  UMask = "0077";
}
