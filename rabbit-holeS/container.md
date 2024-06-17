# docker

## multiple platforms

```sh
docker run --privileged --rm tonistiigi/binfmt --install all
docker buildx create --name mybuilder --bootstrap
docker buildx ls

docker buildx --builder mybuilder build -t test -f test.Dockerfile --platform linux/arm64,linux/amd64 .

docker buildx use default
docker buildx rm mybuilder
```
