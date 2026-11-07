{ inputs, ... }:
let
  ruleFile =
    input: file:
    builtins.path {
      path = input + "/${file}";
      name = builtins.replaceStrings [ "!" ] [ "not-" ] file;
    };
in
{
  site.network = {
    ipv6.enable = false;
    localAccess.enable = true;
    dns.enable = true;
    singBox.enable = true;
    lockdown.enable = true;
    routeFragments = {
      "70-geosite-global.json" = {
        rule_set = [
          {
            type = "local";
            tag = "geosite-global";
            format = "binary";
            path = ruleFile inputs.sing-box-geosite "geosite-geolocation-!cn.srs";
          }
        ];
        rules = [
          {
            rule_set = [ "geosite-global" ];
            action = "route";
            outbound = "proxy";
          }
        ];
      };
      "80-geosite-cn.json" = {
        rule_set = [
          {
            type = "local";
            tag = "geosite-cn";
            format = "binary";
            path = ruleFile inputs.sing-box-geosite "geosite-cn.srs";
          }
        ];
        rules = [
          {
            rule_set = [ "geosite-cn" ];
            action = "route";
            outbound = "direct";
          }
        ];
      };
    };
    ipRuleSets = [
      {
        tag = "geoip-cn";
        type = "local";
        format = "binary";
        path = ruleFile inputs.sing-box-geoip "geoip-cn.srs";
      }
    ];
  };
}
