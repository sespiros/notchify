{
  description = "notchify — notch-style notifications for macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: let
    systems = [ "aarch64-darwin" "x86_64-darwin" ];
    forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
  in {
    packages = forAll (pkgs: rec {
      default = notchify;

      # Notchify uses macOS 13+ APIs (SMAppService) that aren't reliably
      # available via nixpkgs' standalone Swift SDK, so the build relies
      # on the host Xcode.app toolchain. Build with `nix build --impure`.
      notchify = pkgs.stdenvNoCC.mkDerivation {
        pname = "notchify";
        version = "0.3.1";
        src = ./.;

        # Allow access to /Applications/Xcode.app and /usr/bin/codesign
        # outside the nix sandbox.
        __noChroot = true;

        nativeBuildInputs = [ ];

        buildPhase = ''
          runHook preBuild

          export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
          unset SDKROOT
          # Swift PM caches under $HOME/Library; the nix build has no HOME,
          # so point it at a writable temp dir.
          export HOME=$TMPDIR/home
          mkdir -p "$HOME"
          # --disable-sandbox keeps Swift PM from invoking its own
          # sandbox-exec (which the nix build sandbox refuses to nest).
          /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
            build -c release --disable-sandbox --build-path $TMPDIR/build

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall

          mkdir -p $out/bin
          mkdir -p $out/Applications/Notchify.app/Contents/{MacOS,Resources}

          cp $TMPDIR/build/release/notchify        $out/bin/notchify
          cp $TMPDIR/build/release/notchify-daemon $out/Applications/Notchify.app/Contents/MacOS/notchify-daemon
          cp $TMPDIR/build/release/notchify        $out/Applications/Notchify.app/Contents/MacOS/notchify
          cp Resources/Info.plist                  $out/Applications/Notchify.app/Contents/Info.plist
          if [ -f Resources/AppIcon.icns ]; then
            cp Resources/AppIcon.icns $out/Applications/Notchify.app/Contents/Resources/AppIcon.icns
          fi

          /usr/bin/codesign --force --sign - --deep $out/Applications/Notchify.app

          runHook postInstall
        '';

        meta = with pkgs.lib; {
          description = "Notch-style notifications for macOS";
          platforms = platforms.darwin;
          license = licenses.mit;
        };
      };
    });

    # nix-darwin module. Import it from your darwin configuration:
    #   imports = [ inputs.notchify.darwinModules.default ];
    #   programs.notchify.enable = true;
    darwinModules.default = { config, lib, pkgs, ... }: let
      cfg = config.programs.notchify;
      pkg = self.packages.${pkgs.stdenv.hostPlatform.system}.notchify;
    in {
      options.programs.notchify = {
        enable = lib.mkEnableOption "notchify menubar app and CLI";
        package = lib.mkOption {
          type = lib.types.package;
          default = pkg;
          description = "Notchify package to install.";
        };
      };

      config = lib.mkIf cfg.enable {
        environment.systemPackages = [ cfg.package ];

        # Run the daemon as a per-user LaunchAgent so the menubar icon
        # appears at login. We deliberately do NOT copy the .app bundle
        # into /Applications — that would race with the drag-install
        # path and leave a stale Notchify.app behind on every rebuild.
        # Drag-install users on plain macOS still get their .app at
        # /Applications/Notchify.app the normal way.
        launchd.user.agents.notchify = {
          serviceConfig = {
            ProgramArguments = [
              "${cfg.package}/Applications/Notchify.app/Contents/MacOS/notchify-daemon"
            ];
            RunAtLoad = true;
            # KeepAlive on SuccessfulExit=false: launchd respawns
            # only when the daemon crashes (non-zero exit). A clean
            # Quit from the menubar (NSApp.terminate → exit 0) is
            # respected and stays stopped.
            KeepAlive = { SuccessfulExit = false; };
            StandardOutPath = "/tmp/notchify-daemon.out.log";
            StandardErrorPath = "/tmp/notchify-daemon.err.log";
          };
        };
      };
    };
  };
}
