use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let wasmz_root = locate_wasmz_root();
    rerun_if_changed(&wasmz_root);

    if Command::new("zig").arg("version").output().is_err() {
        panic!(
            "zig is required to build wasmz-sys (Zig 0.16). \
             Install from https://ziglang.org/download/"
        );
    }

    let mut zig = Command::new("zig");
    zig.args(["build", "static-lib", "-Doptimize=ReleaseFast"]);
    if let Some(target) = windows_zig_target() {
        zig.arg(format!("-Dtarget={target}"));
    }

    let status = zig
        .current_dir(&wasmz_root)
        .status()
        .expect("failed to spawn zig");

    if !status.success() {
        panic!("zig build static-lib failed with status: {status}");
    }

    let lib_dir = wasmz_root.join("zig-out/lib");
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=wasmz");

    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os != "windows" {
        println!("cargo:rustc-link-lib=c");
    }
}

/// Zig picks the mingw ABI for its native Windows target, which leaves the
/// archive referencing `___chkstk_ms` and ntdll entry points that the MSVC
/// toolchain cannot resolve. Everywhere else Zig's native default already
/// matches what rustc links against.
fn windows_zig_target() -> Option<String> {
    if env::var("CARGO_CFG_TARGET_OS").ok()? != "windows" {
        return None;
    }
    let arch = env::var("CARGO_CFG_TARGET_ARCH").ok()?;
    let abi = match env::var("CARGO_CFG_TARGET_ENV")
        .unwrap_or_default()
        .as_str()
    {
        "gnu" => "gnu",
        _ => "msvc",
    };
    Some(format!("{arch}-windows-{abi}"))
}

fn locate_wasmz_root() -> PathBuf {
    if let Ok(root) = env::var("WASMZ_ROOT") {
        let root = PathBuf::from(root);
        assert_wasmz_root(&root);
        return root;
    }

    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let root = manifest_dir.join("../..");
    assert_wasmz_root(&root);
    root.canonicalize().unwrap_or(root)
}

fn assert_wasmz_root(root: &Path) {
    if !root.join("build.zig").is_file() {
        panic!(
            "invalid wasmz root at {}: build.zig not found",
            root.display()
        );
    }
}

fn rerun_if_changed(wasmz_root: &Path) {
    println!(
        "cargo:rerun-if-changed={}",
        wasmz_root.join("build.zig").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        wasmz_root.join("include/wasmz.h").display()
    );
    println!("cargo:rerun-if-env-changed=ZIG");
    println!("cargo:rerun-if-env-changed=PATH");
    println!("cargo:rerun-if-env-changed=WASMZ_ROOT");

    for path in walk_dir(wasmz_root.join("src")) {
        if path.extension().is_some_and(|ext| ext == "zig") {
            println!("cargo:rerun-if-changed={}", path.display());
        }
    }
}

fn walk_dir(dir: PathBuf) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                out.extend(walk_dir(path));
            } else {
                out.push(path);
            }
        }
    }
    out
}
