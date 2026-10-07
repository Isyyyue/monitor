//! Puts the public theme where `rust-embed` will find it.
//!
//! The theme's source lives in `web-theme/`; `scripts/theme.sh` stages its
//! built output into `target/theme/`. Running it here lets a plain
//! `cargo build` proceed without a setup step.

use std::process::Command;

fn main() {
    // Cargo reruns this only when one of these changes. The theme's own files
    // are listed rather than the staging directory, so editing the theme and
    // rebuilding its dist/ is what triggers the restage.
    println!("cargo:rerun-if-changed=web-theme/dist");
    println!("cargo:rerun-if-changed=web-theme/theme.json");
    println!("cargo:rerun-if-changed=scripts/theme.sh");
    println!("cargo:rerun-if-changed=Cargo.toml");
    // The panel is embedded by `frontend.rs`, and a build script that emits any
    // `rerun-if-changed` at all replaces cargo's own "something in the package
    // changed" heuristic. Without this line a rebuilt `web-admin/dist` triggers
    // no rebuild, and the hub keeps serving the previous bundle in silence --
    // which is how a panel change can be built, tested and then not shipped.
    println!("cargo:rerun-if-changed=web-admin/dist");

    match Command::new("sh").arg("scripts/theme.sh").status() {
        Ok(status) if status.success() => {}
        Ok(status) => panic!("scripts/theme.sh failed ({status}); see the message above"),
        Err(e) => panic!("could not run scripts/theme.sh: {e}"),
    }
}
