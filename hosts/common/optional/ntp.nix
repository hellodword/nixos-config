{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    ntp # ntpdate
  ];

  services.openntpd = {
    enable = false;
  };

  services.ntp = {
    enable = false;
  };

  services.timesyncd = {
    enable = true;
    servers = [
      # China
      "ntp.ntsc.ac.cn"
      "114.118.7.161"
      "114.118.7.163"

      "cn.ntp.org.cn"
      "120.25.108.11"
      "114.67.237.130"
      "1.14.61.51"

      "ntp1.aliyun.com"
      "120.25.115.20"

      "ntp2.aliyun.com"
      "203.107.6.88"

      "ntp.tencent.com"
      "106.55.184.199"

      "ntp1.tencent.com"
      "106.55.184.199"

      "ntp2.tencent.com"
      "111.230.189.174"

      "ntp3.tencent.com"
      "ntp4.tencent.com"
      "ntp5.tencent.com"
      "ntp.sjtu.edu.cn"
      "ntp.neu.edu.cn"
      "ntp.bupt.edu.cn"
      "ntp.shu.edu.cn"
      "ntp.tuna.tsinghua.edu.cn"
      "cn.pool.ntp.org"
      "0.cn.pool.ntp.org"
      "1.cn.pool.ntp.org"
      "2.cn.pool.ntp.org"
      "3.cn.pool.ntp.org"

      # apple
      "time.apple.com"
      "time1.apple.com"
      "time2.apple.com"
      "time3.apple.com"
      "time4.apple.com"
      "time5.apple.com"
      "time6.apple.com"
      "time7.apple.com"

      # microsoft
      "time.windows.com"
      "168.61.215.74"
    ];
  };

  # # # 直连
  # # systemd.services.chronyd.serviceConfig.ExecStartPre = lib.optionals config.services.v2ray.enable [
  # #   "+${pkgs.bash}/bin/bash -c '${pkgs.iptables}/bin/iptables -w 3 -t mangle -C V2RAY_MARK -m owner --uid-owner chrony -j RETURN || ${pkgs.iptables}/bin/iptables -w 3 -t mangle -I V2RAY_MARK -m owner --uid-owner chrony -j RETURN || true'"
  # # ];

  # services.chrony = {
  #   enable = true;
  #   # https://gist.github.com/jauderho/2ad0d441760fc5ed69d8d4e2d6b35f8d
  #   # https://netfuture.ch/2021/12/transparent-trustworthy-time-with-ntp-and-nts/#server-list
  #   enableNTS = false;
  #   servers = [
  #     # # Cloudflare (Anycast)
  #     # "time.cloudflare.com"

  #     # # System76
  #     # "virginia.time.system76.com"
  #     # "ohio.time.system76.com"
  #     # "oregon.time.system76.com"

  #     # # Netnod (Sweden)
  #     # "nts.netnod.se:4460" # Anycast
  #     # "sth1.nts.netnod.se:4460" # Stockholm 
  #     # "sth2.nts.netnod.se:4460" # Stockholm 
  #     # "nts.netnod.se"

  #     # # Physikalisch-Technische Bundesanstalt / PTB (Germany)
  #     # "ptbtime1.ptb.de"
  #     # "ptbtime2.ptb.de"
  #     # "ptbtime3.ptb.de"

  #     # # Time.nl (Netherlands)
  #     # "ntppool1.time.nl"
  #     # "ntppool2.time.nl"

  #     # "a.st1.ntp.br"
  #     # "b.st1.ntp.br"
  #     # "c.st1.ntp.br"
  #     # "d.st1.ntp.br"
  #     # "gps.ntp.br"

  #     # China
  #     "ntp.ntsc.ac.cn"
  #     "114.118.7.161"
  #     "114.118.7.163"

  #     "cn.ntp.org.cn"
  #     "120.25.108.11"
  #     "114.67.237.130"
  #     "1.14.61.51"

  #     "ntp1.aliyun.com"
  #     "120.25.115.20"

  #     "ntp2.aliyun.com"
  #     "203.107.6.88"

  #     "ntp.tencent.com"
  #     "106.55.184.199"

  #     "ntp1.tencent.com"
  #     "106.55.184.199"

  #     "ntp2.tencent.com"
  #     "111.230.189.174"

  #     "ntp3.tencent.com"
  #     "ntp4.tencent.com"
  #     "ntp5.tencent.com"
  #     "ntp.sjtu.edu.cn"
  #     "ntp.neu.edu.cn"
  #     "ntp.bupt.edu.cn"
  #     "ntp.shu.edu.cn"
  #     "ntp.tuna.tsinghua.edu.cn"
  #     "cn.pool.ntp.org"
  #     "0.cn.pool.ntp.org"
  #     "1.cn.pool.ntp.org"
  #     "2.cn.pool.ntp.org"
  #     "3.cn.pool.ntp.org"

  #     # apple
  #     "time.apple.com"
  #     "time1.apple.com"
  #     "time2.apple.com"
  #     "time3.apple.com"
  #     "time4.apple.com"
  #     "time5.apple.com"
  #     "time6.apple.com"
  #     "time7.apple.com"

  #     # microsoft
  #     "time.windows.com"
  #     "168.61.215.74"
  #   ];

  #   # extraConfig = ''
  #   #   minsources 1
  #   #   authselectmode require

  #   #   leapsectz right/UTC
  #   #   makestep 0.1 3

  #   #   rtcsync
  #   #   cmdport 0
  #   # '';

  #   # https://github.com/teto/home/blob/ee3ed2db58920cc5e8d4cedd68118f7c12b7642c/modules/ntp.nix#LL37C1-L41C7
  #   # to correct big errors on startup
  #   initstepslew = {
  #     enabled = true;
  #     threshold = 100;
  #   };
  # };

  # environment.persistence = {
  #   "${persistPath}".directories = [
  #     "/var/lib/chrony"
  #   ];
  # };
}
