# Nix Learning

## background

- https://en.wikipedia.org/wiki/DLL_Hell

## FAQ

- [Which channel branch should I use?](https://nix.dev/concepts/faq#channel-branches)

## quick start

- https://zero-to-nix.com/

  > 基于 flakes，面向开发者，可以让人快速上手开发环境（提供了很多种语言的 flake template）的搭建。并且提供了 [fh](https://github.com/DeterminateSystems/fh) 工具，可以快速设置不同开发环境的 `flake.nix` 以及 `shell.nix`。

- https://nixos-and-flakes.thiscute.world/zh/the-nix-language/

  > 中国人写的册子，基于 flakes，是从安装 NixOS 的用户和开发者的视角，对于上手 NixOS 非常实用。

- https://mhwombat.codeberg.page/nix-book/ | [src](https://discourse.nixos.org/t/wombats-book-of-nix-more-explain-y/35680/1)

  > 基于 flakes 的册子，从它的 hello-flake 开始一步步到构建一个 haskell 和 python 开发环境的 flake.nix

- https://nixos.asia/en/tutorial

- https://github.com/nix-community/todomvc-nix

- https://nixos.org/guides/nix-pills/

- https://nix.dev/tutorials/first-steps/ad-hoc-shell-environments
- https://nix.dev/tutorials/first-steps/reproducible-scripts
- https://nix.dev/tutorials/first-steps/declarative-shell
- https://nix.dev/tutorials/first-steps/towards-reproducibility-pinning-nixpkgs
- https://nix.dev/tutorials/nix-language
- https://nix.dev/tutorials/packaging-existing-software
- https://nix.dev/tutorials/callpackage
- https://nix.dev/tutorials/nixos/nixos-configuration-on-vm
- https://nix.dev/tutorials/nixos/integration-testing-using-virtual-machines
- https://nix.dev/tutorials/nixos/building-bootable-iso-image

## flakes

- https://wiki.nixos.org/wiki/Flakes
- https://zero-to-nix.com/concepts/flakes
- https://nix.dev/concepts/flakes#why-are-flakes-controversial
- https://jade.fyi/blog/flakes-arent-real/
- https://discourse.nixos.org/t/experimental-does-not-mean-unstable-detsyss-perspective-on-nix-flakes/32703/1

## internal

- https://edolstra.github.io/pubs/phd-thesis.pdf

- https://nixos.org/guides/how-nix-works/

- https://shopify.engineering/what-is-nix

- https://nix.dev/tutorials/module-system/module-system

- Nix manual: https://nixos.org/manual/nix/stable/

- Nixpkgs manual: https://nixos.org/manual/nixpkgs/stable/

  - https://ryantm.github.io/nixpkgs/

- NixOS manual: https://nixos.org/manual/nixos/stable/

## usage

- CI

  - https://determinate.systems/posts/nix-github-actions/

- Docker

  - https://github.com/NixOS/nixpkgs/blob/master/pkgs/build-support/docker/examples.nix

## wiki

- https://wiki.nixos.org

## tools

- https://github.com/DeterminateSystems/nix-installer
- https://github.com/DeterminateSystems/fh
- https://github.com/DeterminateSystems/flake-checker

## others

- https://zaynetro.com/post/2024-you-dont-need-home-manager-nix
