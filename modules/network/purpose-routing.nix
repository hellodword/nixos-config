{
  config,
  lib,
  inputs,
  pkgs,
  ...
}:
let
  catalog = builtins.fromTOML (builtins.readFile ../../data/network/purposes.toml);
  rules = lib.imap0 (
    index: rule: rule // { order = lib.fixedWidthNumber 3 (index + 1); }
  ) catalog.rules;
  nativeRule =
    rule:
    builtins.removeAttrs rule [
      "scope"
      "order"
      "shadowrocket"
    ]
    // lib.optionalAttrs (rule ? rules) { rules = map nativeRule rule.rules; }
    // lib.optionalAttrs ((rule.action or null) == "resolve") { server = "dns-policy"; };
  referencedSets = rule: (rule.rule_set or [ ]) ++ lib.concatMap referencedSets (rule.rules or [ ]);
  domainTags = lib.unique (
    lib.concatMap referencedSets (lib.filter (rule: rule.scope == "domain") rules)
  );
  seeds = lib.mapAttrsToList (input: prefix: {
    source = inputs.${input};
    inherit prefix;
  }) catalog.seeds;
  definition =
    tag:
    let
      source = catalog.rule_sets.${tag};
      seed = lib.findFirst (seed: lib.hasPrefix seed.prefix source.url) null seeds;
    in
    catalog.rule_set_defaults
    // builtins.removeAttrs source [
      "shadowrocket"
      "seed"
    ]
    // {
      inherit tag;
      initial_path =
        if source ? seed then
          pkgs.fetchurl source.seed
        else
          builtins.path {
            path = seed.source + "/${lib.removePrefix seed.prefix source.url}";
            name = builtins.replaceStrings [ "!" "@" ] [ "not-" "-" ] (builtins.baseNameOf source.url);
          };
    };
  fragments =
    scope:
    let
      selected = lib.filter (rule: rule.scope == scope) rules;
      tags = lib.filter (tag: scope == "domain" || !(lib.elem tag domainTags)) (
        lib.unique (lib.concatMap referencedSets selected)
      );
    in
    builtins.listToAttrs (
      map (rule: {
        name = "40-purpose-${rule.order}.json";
        value = {
          rules = [ (nativeRule rule) ];
        };
      }) selected
    )
    // {
      "40-purpose-000-${scope}.json" = {
        rule_set = map (
          tag:
          builtins.removeAttrs (definition tag) (
            lib.optionals (scope == "domain") [
              "http_client"
              "update_interval"
            ]
          )
        ) tags;
      }
      // lib.optionalAttrs (scope == "domain") { inherit (catalog) final; };
    };
in
{
  options.site.network.purposeRouting.enable = lib.mkEnableOption "shared client purpose routing";
  config = lib.mkIf config.site.network.purposeRouting.enable {
    site.network.purposeGroups = lib.mkDefault (
      lib.unique (
        lib.filter (
          name:
          name != null
          && !(lib.elem name [
            "direct"
            "proxy"
          ])
        ) (map (rule: rule.outbound or null) rules)
      )
    );
    site.network.routeFragments = fragments "domain";
    site.network.connectionFragments = fragments "connection";
  };
}
