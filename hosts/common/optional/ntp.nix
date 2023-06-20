{ persistPath, ... }:

{
  services.openntpd = {
    enable = false;
  };

  services.ntp = {
    enable = false;
  };

  services.timesyncd = {
    enable = false;
  };

  services.chrony = {
    enable = true;
    # https://gist.github.com/jauderho/2ad0d441760fc5ed69d8d4e2d6b35f8d
    # https://netfuture.ch/2021/12/transparent-trustworthy-time-with-ntp-and-nts/#server-list
    enableNTS = true;
    servers = [
      # Cloudflare (Anycast)
      "time.cloudflare.com"

      # System76
      "virginia.time.system76.com"
      "ohio.time.system76.com"
      "oregon.time.system76.com"

      # Netnod (Sweden)
      "nts.netnod.se:4460" # Anycast
      "sth1.nts.netnod.se:4460" # Stockholm 
      "sth2.nts.netnod.se:4460" # Stockholm 
      "nts.netnod.se"

      # Physikalisch-Technische Bundesanstalt / PTB (Germany)
      "ptbtime1.ptb.de"
      "ptbtime2.ptb.de"
      "ptbtime3.ptb.de"

      # Time.nl (Netherlands)
      "ntppool1.time.nl"
      "ntppool2.time.nl"

      "a.st1.ntp.br"
      "b.st1.ntp.br"
      "c.st1.ntp.br"
      "d.st1.ntp.br"
      "gps.ntp.br"
    ];

    extraConfig = ''
      minsources 2
      authselectmode require

      leapsectz right/UTC
      makestep 0.1 3

      rtcsync
      cmdport 0
    '';

    # https://github.com/teto/home/blob/ee3ed2db58920cc5e8d4cedd68118f7c12b7642c/modules/ntp.nix#LL37C1-L41C7
    # to correct big errors on startup
    initstepslew = {
      enabled = true;
      threshold = 100;
    };
  };

  environment.persistence = {
    "${persistPath}".directories = [
      "/var/lib/chrony"
    ];
  };
}
