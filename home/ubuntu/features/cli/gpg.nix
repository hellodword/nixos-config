{ pkgs, config, ... }:

{
  # TODO

  home.packages = with pkgs; [
    monkeysphere # openpgp2ssh
  ];

  services.gpg-agent = {
    enable = true;
    enableBashIntegration = config.programs.bash.enable;
    enableSshSupport = config.programs.ssh.enable;
    extraConfig = '''';
    /*
      gpg --list-keys --with-keygrip | grep -A 1 '\[A'
      ~/.gnupg/sshcontrol
    */
    # sshKeys = inputs.privates.gpg."<...>".sshKeys;
    verbose = false;
  };

  # programs.git.aliases."signing" = "!git config commit.gpgsign true && git config user.signingkey ${inputs.privates.gpg."<...>".git-signingkey}";

  programs.gpg = {
    enable = true;
    homedir = "${config.home.homeDirectory}/.gnupg";
    mutableKeys = true;
    mutableTrust = true;
    publicKeys = [
      {
        # https://github.com/web-flow.gpg
        trust = "ultimate";
        text = ''
          -----BEGIN PGP PUBLIC KEY BLOCK-----

          xsBNBFmUaEEBCACzXTDt6ZnyaVtueZASBzgnAmK13q9Urgch+sKYeIhdymjuMQta
          x15OklctmrZtqre5kwPUosG3/B2/ikuPYElcHgGPL4uL5Em6S5C/oozfkYzhwRrT
          SQzvYjsE4I34To4UdE9KA97wrQjGoz2Bx72WDLyWwctD3DKQtYeHXswXXtXwKfjQ
          7Fy4+Bf5IPh76dA8NJ6UtjjLIDlKqdxLW4atHe6xWFaJ+XdLUtsAroZcXBeWDCPa
          buXCDscJcLJRKZVc62gOZXXtPfoHqvUPp3nuLA4YjH9bphbrMWMf810Wxz9JTd3v
          yWgGqNY0zbBqeZoGv+TuExlRHT8ASGFS9SVDABEBAAHNNUdpdEh1YiAod2ViLWZs
          b3cgY29tbWl0IHNpZ25pbmcpIDxub3JlcGx5QGdpdGh1Yi5jb20+wsBiBBMBCAAW
          BQJZlGhBCRBK7hj4Ov3rIwIbAwIZAQAAmQEIACATWFmi2oxlBh3wAsySNCNV4IPf
          DDMeh6j80WT7cgoX7V7xqJOxrfrqPEthQ3hgHIm7b5MPQlUr2q+UPL22t/I+ESF6
          9b0QWLFSMJbMSk+BXkvSjH9q8jAO0986/pShPV5DU2sMxnx4LfLfHNhTzjXKokws
          +8ptJ8uhMNIDXfXuzkZHIxoXk3rNcjDN5c5X+sK8UBRH092BIJWCOfaQt7v7wig5
          4Ra28pM9GbHKXVNxmdLpCFyzvyMuCmINYYADsC848QQFFwnd4EQnupo6QvhEVx1O
          j7wDwvuH5dCrLuLwtwXaQh0onG4583p0LGms2Mf5F+Ick6o/4peOlBoZz48=
          =HXDP
          -----END PGP PUBLIC KEY BLOCK-----
        '';
      }
    ];
    settings = {
      #
      # This is an implementation of the Riseup OpenPGP Best Practices
      # https://help.riseup.net/en/security/message-security/openpgp/best-practices
      #


      #-----------------------------
      # default key
      #-----------------------------

      # The default key to sign with. If this option is not used, the default key is
      # the first key found in the secret keyring

      #default-key 0xD8692123C4065DEA5E0F3AB5249B39D24F25E3B6


      #-----------------------------
      # behavior
      #-----------------------------

      # Disable inclusion of the version string in ASCII armored output
      no-emit-version = true;

      # Disable comment string in clear text signatures and ASCII armored messages
      no-comments = true;

      # Display long key IDs
      keyid-format = "0xlong";

      # List all keys (or the specified ones) along with their fingerprints
      with-fingerprint = true;

      # Display the calculated validity of user IDs during key listings
      list-options = "show-uid-validity";
      verify-options = "show-uid-validity";

      # Try to use the GnuPG-Agent. With this option, GnuPG first tries to connect to
      # the agent before it asks for a passphrase.
      use-agent = true;


      #-----------------------------
      # keyserver
      #-----------------------------

      # This is the server that --recv-keys, --send-keys, and --search-keys will
      # communicate with to receive keys from, send keys to, and search for keys on
      # keyserver="hkps://keys.openpgp.org/"

      # Set the proxy to use for HTTP and HKP keyservers - default to the standard
      # local Tor socks proxy
      # It is encouraged to use Tor for improved anonymity. Preferrably use either a
      # dedicated SOCKSPort for GnuPG and/or enable IsolateDestPort and
      # IsolateDestAddr
      #keyserver-options http-proxy=socks5-hostname://127.0.0.1:9050

      # Don't leak DNS, see https://trac.torproject.org/projects/tor/ticket/2846
      # keyserver-options no-try-dns-srv

      # When using --refresh-keys, if the key in question has a preferred keyserver
      # URL, then disable use of that preferred keyserver to refresh the key from
      # keyserver-options no-honor-keyserver-url

      # When searching for a key with --search-keys, include keys that are marked on
      # the keyserver as revoked
      # keyserver-options include-revoked


      #-----------------------------
      # algorithm and ciphers
      #-----------------------------

      # list of personal digest preferences. When multiple digests are supported by
      # all recipients, choose the strongest one
      personal-cipher-preferences = "AES256 AES192 AES CAST5";

      # list of personal digest preferences. When multiple ciphers are supported by
      # all recipients, choose the strongest one
      personal-digest-preferences = "SHA512 SHA384 SHA256 SHA224";

      # message digest algorithm used when signing a key
      cert-digest-algo = "SHA512";

      # This preference list is used for new keys and becomes the default for
      # "setpref" in the edit menu
      default-preference-list = "SHA512 SHA384 SHA256 SHA224 AES256 AES192 AES CAST5 ZLIB BZIP2 ZIP Uncompressed";

      with-keygrip = true;
    };
  };

  # # gpg: WARNING: unsafe permissions on homedir
  ## use environment.persistence
  # home.persistence = {
  #   "${persistPath}${config.home.homeDirectory}".directories = [ ".gnupg" ];
  # };
}
