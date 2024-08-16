{ lib, ... }:

with lib;
with types;
{
  options.me.sing-box-bypass-services = mkOption {
    type = listOf (submodule {
      options = {
        user = mkOption {
          type = with types; str;
        };

        service = mkOption {
          type = with types;  str;
        };
      };
    });
    default = [ ];
  };

  options.me.sing-box-log-disabled = mkOption {
    type = bool;
    default = false;
  };

  config = { };
}
