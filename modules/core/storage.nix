{ lib, ... }:
{
  options.site.storage.persistRoot = lib.mkOption {
    type = lib.types.pathWith {
      absolute = true;
      inStore = false;
    };
    default = "/persist";
    description = "Mount point of the existing persistent filesystem.";
  };
}
