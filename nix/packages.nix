{
  pkgs,
  inputs,
  system ? pkgs.stdenv.hostPlatform.system,
}:
let
  remote = inputs.nixpkgs-remote.legacyPackages.${system};
in
{
  oranc = inputs.oranc.packages.${system}.oranc;
  vps-python = remote.python3.withPackages (p: [ p.pyyaml ]);
  wrangler = import ./wrangler.nix { pkgs = remote; };
  # The existing laptop fix is also a public, reusable cache output.
  virtualbox = pkgs.virtualbox.overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      if [ -e "$out/libexec/virtualbox/VBoxDxVk.so" ]; then
        patchelf --add-rpath ${pkgs.lib.makeLibraryPath [ pkgs.vulkan-loader ]} \
          "$out/libexec/virtualbox/VBoxDxVk.so"
      fi
    '';
  });
}
