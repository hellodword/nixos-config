{
  programs.starship = {
    enable = true;
    enableBashIntegration = true;
    settings = {
      # $all is shorthand for $username$hostname$localip$shlvl$singularity$kubernetes$nats$directory$vcsh$fossil_branch$fossil_metrics$git_branch$git_commit$git_state$git_metrics$git_status$hg_branch$pijul_channel$docker_context$package$bun$c$cmake$cobol$daml$dart$deno$dotnet$elixir$elm$erlang$fennel$gleam$golang$gradle$haskell$haxe$helm$java$julia$kotlin$lua$nim$nodejs$ocaml$odin$opa$perl$php$pulumi$purescript$python$quarto$raku$rlang$red$ruby$rust$scala$solidity$swift$terraform$typst$vlang$vagrant$zig$buf$guix_shell$nix_shell$conda$meson$spack$memory_usage$aws$gcloud$openstack$azure$direnv$env_var$crystal$custom$sudo$cmd_duration$line_break$jobs$battery$time$status$container$os$shell$character
      # https://github.com/starship/starship/blob/522aa31f0844a70771c15582b28254ba1db89fab/src/configs/starship_root.rs#L33
      aws.disabled = true;
      azure.disabled = true;
      buf.disabled = true;
      localip.disabled = true;
      gcloud.disabled = true;
      git_status.disabled = true;
      os.disabled = true;
      package.disabled = true;
      python.disabled = true;
      time.disabled = true;
      vcsh.disabled = true;
      shlvl.disabled = false;
      sudo.disabled = false;
    };
  };
}
