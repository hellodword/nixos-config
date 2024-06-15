# shell (scripts)

## loop LTD

```sh
# with NS
curl -fsSL https://data.iana.org/TLD/tlds-alpha-by-domain.txt | grep -oPi '^[a-z\d]+$' | \
    xargs -I {} bash -c 'if test "$(dig +short NS nixos.{} | wc -l)" -gt "0"; then (echo nixos.{}) fi' | \
    tee ns.log

cat ns.log | xargs -I {} bash -c 'if test "$((dig +short A {}; dig +short AAAA {}) | wc -l)" -gt "0"; then (echo {}) fi'
```

## URL Encode

```sh
jq -rn --arg x "$(echo -e 'hello\nworld')" '$x|@uri'
```

## get directory path of shell script

```sh
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

"$DIR/test2.sh" "$@"
```
