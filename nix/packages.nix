{ pkgs, inputs }:
{
  oranc = inputs.oranc.packages.${pkgs.stdenv.hostPlatform.system}.oranc;
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
