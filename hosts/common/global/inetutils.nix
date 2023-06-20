{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [ inetutils ];

  security = {
    wrappers.ping6 = {
      owner = "root";
      group = "root";
      source = "${pkgs.inetutils}/bin/ping6";
      capabilities = "cap_net_raw+p";
    };
  };
}
