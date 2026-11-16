{ test, pkgs }:
(test.extend {
  modules = [ { globalTimeout = pkgs.lib.mkForce (test.config.globalTimeout * 2); } ];
}).overrideTestDerivation
  (old: {
    name = old.name + "-cpu-pressure";
    buildCommand = ''
      ${pkgs.python3}/bin/python3 ${./cpu_pressure.py} ${pkgs.stress-ng}/bin/stress-ng \
        ${pkgs.writeShellScript "native-vm-test" old.buildCommand}
    '';
  })
