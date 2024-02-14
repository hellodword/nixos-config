# Snippets

## get derivation size (DL and Nar)

```sh
curl https://cache.nixos.org/"$(
        nix derivation show nixpkgs#firefox | \
        jq -r '.[] | .outputs.out.path' | grep -oP '(?<=\/)[a-z\d]+(?=\-)'
    )".narinfo
```

## set proxy for nix-deamon temporarily

> https://github.com/NixOS/nixpkgs/issues/27535#issuecomment-1178444327

```sh
sudo mkdir /run/systemd/system/nix-daemon.service.d/
cat << EOF >/run/systemd/system/nix-daemon.service.d/override.conf
[Service]
Environment="http_proxy=socks5h://localhost:7891"
Environment="https_proxy=socks5h://localhost:7891"
Environment="all_proxy=socks5h://localhost:7891"
EOF
sudo systemctl daemon-reload
sudo systemctl restart nix-daemon
```

## json2nix

- https://gist.github.com/Scoder12/0538252ed4b82d65e59115075369d34d
- https://haseebmajid.dev/posts/2023-11-06-a-simple-way-to-convert-json-to-nix-attribute-sets/
  - https://gitlab.com/-/snippets/3613708

```sh
nix eval --expr 'builtins.fromJSON (builtins.readFile ./data.json)' --impure | nixfmt
```

## locate source file of function

```sh
❯ nix repl -f '<nixpkgs>'
Welcome to Nix 2.18.1. Type :? for help.

Loading installable ''...
Added 20435 variables.
nix-repl> builtins.unsafeGetAttrPos "buildGoModule" pkgs
{ column = 3; file = "/nix/store/599wy5snf00pn1apmsnzmiy0ysdpds03-source/pkgs/top-level/all-packages.nix"; line = 25777; }
```
