# Snippets

## get derivation size (DL and Nar)

```sh
curl https://cache.nixos.org/"$(
        nix derivation show nixpkgs#firefox | \
        jq -r '.[] | .outputs.out.path' | grep -oP '(?<=\/)[a-z\d]+(?=\-)'
    )".narinfo
```
