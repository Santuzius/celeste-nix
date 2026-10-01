# celeste-nix

> [!WARNING]
> **Deprecated and archived.** Since [Celeste 0.17.0](https://github.com/Santuzius/celeste/releases/tag/v0.17.0) the package lives in the Celeste repository itself as a flake. It builds fully in the Nix sandbox, so neither this repository, a local checkout nor `--impure` is needed anymore.

## Migration
Add Celeste as a flake input:

```nix
celeste.url = "github:Santuzius/celeste";
```

Then add `inputs.celeste.nixosModules.default` to your modules and set `programs.celeste.enable = true;`. See the [Celeste README](https://github.com/Santuzius/celeste#installing-on-nixos) for details.

Remove `pkgs.callPackage …/celeste-nix` from your configuration and drop `--impure` from your rebuild command.
