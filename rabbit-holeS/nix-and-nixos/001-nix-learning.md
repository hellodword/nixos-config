# Nix Learning

## background

- https://en.wikipedia.org/wiki/DLL_Hell

## FAQ

- [Which channel branch should I use?](https://nix.dev/concepts/faq#channel-branches)

## tutorials

- [x] https://zero-to-nix.com/

  > 基于 flakes，面向开发者，可以让人快速上手开发环境（提供了很多种语言的 flake template）的搭建。并且提供了 [fh](https://github.com/DeterminateSystems/fh) 工具，可以快速设置不同开发环境的 `flake.nix` 以及 `shell.nix`。

- [x] https://nixos-and-flakes.thiscute.world/zh/the-nix-language/

  > 中国人写的册子，基于 flakes，是从安装 NixOS 的用户和开发者的视角。

- [x] https://mhwombat.codeberg.page/nix-book/ | [src](https://discourse.nixos.org/t/wombats-book-of-nix-more-explain-y/35680/1)

  > 基于 flakes 的册子，从它的 hello-flake 开始到构建 haskell 和 python 开发环境的 `flake.nix`。

- [x] https://nixos.asia/en/tutorial

  > 基于 flakes 的教程，包括很多 NixOS 用户常用的东西，例如 disko、home-manager，以及一些开发环境的配置。

- [x] https://nix.dev

  > NixOS 维护的入门教程，可能是由于 flakes 还是 `experimental-features`，所以这系列教程中不包括 flakes。

- [x] https://nixos.org/guides/how-nix-works/

  > 简单介绍了一下 nix store。

## internals

- [x] https://nix.dev/tutorials/module-system/module-system

  > 详解 module system

- [ ] https://nixos.org/guides/nix-pills/

  > NixOS 维护的一系列教程，是从博客整理而来，也没有 flakes。我觉得比其它入门教程更深入，例如 4-9 循序渐进地讲解了为什么以及怎么编写一个通用的 `mkDerivation` 而不只是打包一个 hello，12 开始介绍 nixpkgs 的设计。

- [ ] https://edolstra.github.io/pubs/phd-thesis.pdf

  > Nix 和 NixOS 的理论基础和起源，Eelco Dolstra 的博士论文，在接触 NixOS 的时候会经常遇到别人推荐阅读它。

  - https://jonathanlorimer.dev/posts/nix-thesis.html
  - https://www.youtube.com/playlist?list=PLa01scHy0YEkFRy1mpC-DDjuayJFpwDqp
  - https://www.usenix.org/legacy/event/hotos07/tech/full_papers/dolstra/dolstra_html/

- [ ] https://shopify.engineering/what-is-nix

- [ ] https://www.tweag.io/blog/2022-07-14-taming-unix-with-nix/

- [ ] Nix manual: https://nixos.org/manual/nix/stable/

- [ ] Nixpkgs manual: https://nixos.org/manual/nixpkgs/stable/

  - https://ryantm.github.io/nixpkgs/

- [ ] NixOS manual: https://nixos.org/manual/nixos/stable/

## flakes

- https://wiki.nixos.org/wiki/Flakes
- https://zero-to-nix.com/concepts/flakes
- https://nix.dev/concepts/flakes#why-are-flakes-controversial
- https://jade.fyi/blog/flakes-arent-real/
- https://discourse.nixos.org/t/experimental-does-not-mean-unstable-detsyss-perspective-on-nix-flakes/32703/1

## libraries

- https://github.com/edolstra/flake-compat
- https://github.com/numtide/flake-utils
- https://github.com/gytis-ivaskevicius/flake-utils-plus
- https://github.com/hercules-ci/flake-parts
- https://github.com/divnix/std
- https://github.com/nix-community/haumea

## wiki

- https://wiki.nixos.org

## tools

- https://github.com/DeterminateSystems/nix-installer
- https://github.com/DeterminateSystems/fh
- https://github.com/DeterminateSystems/flake-checker

## nixify

- https://github.com/nix-community/todomvc-nix
- https://github.com/rvolosatovs/nixify
- https://github.com/nixified-ai/flake

- CI

  - https://determinate.systems/posts/nix-github-actions/

- Docker

  - https://github.com/NixOS/nixpkgs/blob/master/pkgs/build-support/docker/examples.nix

## misc

- https://nixos.github.io/release-wiki/Release-Process.html
- https://github.com/NixOS/rfcs/blob/master/rfcs/0085-nixos-release-stablization.md

- https://zaynetro.com/post/2024-you-dont-need-home-manager-nix
