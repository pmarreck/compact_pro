{
	description = "compact_pro: clean-room Compact Pro implementation";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
	};

	outputs = { self, nixpkgs }:
	let
		lib = nixpkgs.lib;
		host_systems = [
			"x86_64-linux"
			"aarch64-linux"
			"x86_64-darwin"
			"aarch64-darwin"
		];
		forAllHosts = f: lib.genAttrs host_systems (system: f (import nixpkgs { inherit system; }));

		mkNativeCliPackage = pkgs: pkgs.stdenv.mkDerivation {
			pname = "compact-pro";
			version = "0.1.0";
			src = self;
			nativeBuildInputs = [ pkgs.zig pkgs.clang pkgs.gcc ];
			buildInputs = lib.optionals pkgs.stdenv.isDarwin [
				pkgs.apple-sdk
			];
			dontConfigure = true;
			buildPhase = ''
				runHook preBuild
				export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
				export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
				mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
				zig build -Doptimize=ReleaseFast
				runHook postBuild
			'';
			installPhase = ''
				runHook preInstall
				mkdir -p $out/bin
				cp zig-out/bin/compact-pro $out/bin/
				runHook postInstall
			'';
		};

		mkCiCheck = pkgs: cfg: pkgs.stdenv.mkDerivation {
			pname = "compact-pro-ci-${cfg.name}";
			version = "0.1.0";
			src = self;
			nativeBuildInputs = [
				pkgs.zig
				pkgs.clang
				pkgs.gcc
				pkgs.bash
				pkgs.coreutils
				pkgs.diffutils
				pkgs.findutils
				pkgs.gnugrep
				pkgs.gnused
				pkgs.xxd
			];
			buildInputs = lib.optionals pkgs.stdenv.isDarwin [
				pkgs.apple-sdk
			];
			dontConfigure = true;
			buildPhase = ''
				runHook preBuild
				export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
				export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
				export HOME="$TMPDIR/home"
				mkdir -p "$HOME"
				mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
			'' + lib.optionalString cfg.run_tests ''
				zig build test -Doptimize=ReleaseFast
				bash tests/cli/test_cli.sh
			'' + ''
				zig build -Doptimize=ReleaseFast -Dtarget=${cfg.zig_target}
				runHook postBuild
			'';
			installPhase = ''
				mkdir -p $out
				echo ${cfg.zig_target} > $out/target
			'';
		};

		ci_targets = [
			{
				name = "linux-x86_64";
				builder_system = "x86_64-linux";
				zig_target = "x86_64-linux";
				run_tests = true;
			}
			{
				name = "linux-aarch64";
				builder_system = "x86_64-linux";
				zig_target = "aarch64-linux";
				run_tests = false;
			}
			{
				name = "windows-x86_64";
				builder_system = "x86_64-linux";
				zig_target = "x86_64-windows";
				run_tests = false;
			}
			{
				name = "windows-aarch64";
				builder_system = "x86_64-linux";
				zig_target = "aarch64-windows";
				run_tests = false;
			}
			{
				name = "macos-aarch64";
				builder_system = "aarch64-darwin";
				zig_target = "aarch64-macos";
				run_tests = true;
			}
		];

		ci_builder_systems = lib.unique (map (cfg: cfg.builder_system) ci_targets);
		checksForSystem = system:
			let
				pkgs = import nixpkgs { inherit system; };
				targets = lib.filter (cfg: cfg.builder_system == system) ci_targets;
			in
			lib.listToAttrs (map
				(cfg: {
					name = "ci-${cfg.name}";
					value = mkCiCheck pkgs cfg;
				})
				targets);
	in {
		devShells = forAllHosts (pkgs: {
			default = pkgs.mkShell {
				packages = with pkgs; [
					zig
					clang
					gcc
					gnumake
					pkg-config
					git
					gh
					bash
					hyperfine
					zip
					unzip
					gzip
				];
			};
		});

		packages = forAllHosts (pkgs: {
			compact-pro-cli = mkNativeCliPackage pkgs;
			default = self.packages.${pkgs.stdenv.hostPlatform.system}.compact-pro-cli;
		});

		checks = lib.genAttrs ci_builder_systems checksForSystem;
	};
}
