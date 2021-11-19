{
  description = "Rust mid-level IR Abstract Interpreter";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    naersk.url = "github:nmattia/naersk";
    rust-overlay.url = "github:oxalica/rust-overlay";
    utils.url = "github:numtide/flake-utils";
    import-cargo.url = "github:edolstra/import-cargo";
  };

  outputs = { self, nixpkgs, naersk, rust-overlay, utils, import-cargo }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlay ];
        };

        rust = pkgs.rust-bin.nightly."2021-11-17".minimal.override {
          extensions = [ "rustfmt-preview" "clippy-preview" "rustc-dev" "llvm-tools-preview" ];
        };

        naersk-lib = naersk.lib."${system}".override {
          cargo = rust;
          rustc = rust;
        };

        clang = if pkgs.stdenv.isDarwin then pkgs.llvmPackages_12.clang else pkgs.llvmPackages_13.clang;
        libclang = if pkgs.stdenv.isDarwin then pkgs.llvmPackages_12.libclang else pkgs.llvmPackages_13.libclang;

        mirai-version = "${self.tag or "${self.lastModifiedDate}.${self.shortRev or "dirty"}"}";
      in rec {
        packages = {
          mirai = naersk-lib.buildPackage {
            pname = "mirai";
            version = "${mirai-version}";
            root = pkgs.lib.cleanSource ./.;
            buildInputs = [
              clang
              libclang
              pkgs.z3
            ];

            # Required for naersk to pull nested dependencies into the nix store (https://github.com/nix-community/naersk/issues/190)
            singleStep = true;

            cargoBuildOptions = x: x ++ [ "-p" "mirai" ];
            cargoTestOptions = x: x ++ [ "-p" "mirai" ];

            RUSTFLAGS = "-Clink-arg=-L./binaries -Clink-arg=-lstdc++";
            LIBCLANG_PATH = "${libclang.lib}/lib";
            Z3_SYS_Z3_HEADER = "${pkgs.z3.dev}/include/z3.h";
            RUST_SYSROOT = "${rust}";
          };
        };

        checks = {
          validate-mirai = pkgs.runCommand "validate-mirai" {
            buildInputs = [
              clang
              libclang
              pkgs.z3
              defaultPackage
              rust
              (import-cargo.builders.importCargo {
                lockFile = ./Cargo.lock;
                inherit pkgs;
              }).cargoHome
            ];
          }
          ''
            cp -r ${self}/. $TMP
            cd $TMP

            export LIBCLANG_PATH=${libclang.lib}/lib
            export Z3_SYS_Z3_HEADER=${pkgs.z3.dev}/include/z3.h
            export RUST_SYSROOT=${rust}

            cargo clean
            cargo fmt --all
            cargo clippy --all-features --all-targets --frozen --offline -- -D warnings
            RUSTFLAGS="-Clink-arg=-L./binaries -Clink-arg=-lstdc++" cargo build --frozen --offline

            touch standard_contracts/src/lib.rs
            RUSTFLAGS="-Z force-overflow-checks=off" cargo build --lib -p mirai-standard-contracts --frozen --offline
            touch standard_contracts/src/lib.rs
            RUSTFLAGS="-Z force-overflow-checks=off" RUSTC_WRAPPER=target/debug/mirai RUST_BACKTRACE=1 MIRAI_LOG=warn MIRAI_START_FRESH=true MIRAI_SHARE_PERSISTENT_STORE=true MIRAI_FLAGS="--diag=paranoid" cargo build --lib -p mirai-standard-contracts --frozen --offline

            cd target/debug/deps
            tar -c -f ../../../binaries/summary_store.tar .summary_store.sled
            cd ../../..

            cargo clean
            cargo build --tests --frozen --offline
            time cargo test --frozen --offline

            cargo clean
            RUSTFLAGS="-Z always_encode_mir" cargo check --frozen --offline
            touch checker/src/lib.rs
            RUSTFLAGS="-Z always_encode_mir" RUSTC_WRAPPER=mirai RUST_BACKTRACE=full MIRAI_LOG=warn MIRAI_FLAGS="--body_analysis_timeout 10" cargo check --lib --frozen --offline

            mkdir $out
          '';
        };

        defaultPackage = packages.mirai;
      }
    );
}
