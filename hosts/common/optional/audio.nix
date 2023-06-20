{ lib, ... }:

{
  # https://github.com/balsoft/nixos-config/blob/a0f28267b8e3b822ce8dc673b13a1862ee49e0cb/profiles/sound.nix#L4

  hardware.pulseaudio.enable = lib.mkForce false;

  security.rtkit.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    wireplumber.enable = true;
  };
}
