{
  socketPath ? "/run/site-dns-events/dnstap.sock",
}:
{
  pipelines = [
    {
      name = "dnsdist";
      dnstap = {
        sock-path = socketPath;
        disable-dnsparser = false;
        extended-support = false;
      };
      transforms.extract.add-payload = true;
      routing-policy.forward = [ "journal" ];
    }
    {
      name = "journal";
      stdout = {
        mode = "json";
        flush-interval = 0.1;
      };
    }
  ];
}
