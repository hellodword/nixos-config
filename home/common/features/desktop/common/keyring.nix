{ persistPath, config, ... }:

{
  # # not working https://github.com/nix-community/home-manager/issues/1454
  # # use nixos-module

  # # https://github.com/berbiche/dotfiles/blob/1e4d0501bde814be76419d8f21cf2fb9079e6a93/user/nicolas/home.nix#L96-L99
  # # https://github.com/nix-community/home-manager/issues/1454
  # # Passwords and stuff
  # services.gnome-keyring.enable = true;
  # # I use gpg-agent for ssh and gpg, so only use it for secrets
  # services.gnome-keyring.components = [ "secrets" ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".local/share/keyrings" ];
  };
}
