{
  DynamicUser = true;
  NoNewPrivileges = true;
  ProtectSystem = "strict";
  ProtectHome = true;
  PrivateTmp = true;
  PrivateDevices = true;
  ProtectKernelTunables = true;
  ProtectKernelModules = true;
  ProtectKernelLogs = true;
  ProtectControlGroups = true;
  ProtectClock = true;
  ProtectHostname = true;
  ProtectProc = "invisible";
  RestrictNamespaces = true;
  RestrictRealtime = true;
  RestrictSUIDSGID = true;
  LockPersonality = true;
  RemoveIPC = true;
  UMask = "0077";
  SystemCallArchitectures = "native";
  SystemCallFilter = [ "@system-service" ];
  SystemCallErrorNumber = "EPERM";
  CapabilityBoundingSet = "";
  RestrictAddressFamilies = [
    "AF_UNIX"
    "AF_INET"
    "AF_INET6"
  ];
}
