{
	description = "compact_pro: clean-room Compact Pro implementation";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
	};

	outputs = { self, nixpkgs }:
	let
		lib = nixpkgs.lib;
		systems = [
			"x86_64-linux"
			"aarch64-linux"
			"x86_64-darwin"
			"aarch64-darwin"
		];
		forAllSystems = f: lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
	in {
		devShells = forAllSystems (pkgs: {
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
				];
			};
		});

		packages = forAllSystems (pkgs: {
			compact-pro-cli = pkgs.stdenv.mkDerivation {
				pname = "compact-pro";
				version = "0.1.0";
				src = self;
				nativeBuildInputs = [ pkgs.zig pkgs.clang pkgs.gcc ];
				dontConfigure = true;
				buildPhase = ''
					runHook preBuild
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
			default = self.packages.${pkgs.system}.compact-pro-cli;
		});

		checks = forAllSystems (pkgs: {
			default = pkgs.stdenv.mkDerivation {
				pname = "compact-pro-check";
				version = "0.1.0";
				src = self;
				nativeBuildInputs = [ pkgs.zig pkgs.clang pkgs.gcc pkgs.bash ];
				dontConfigure = true;
				buildPhase = ''
					runHook preBuild
					./test
					runHook postBuild
				'';
				installPhase = ''
					mkdir -p $out
					echo ok > $out/result
				'';
			};
		});
	};
}
