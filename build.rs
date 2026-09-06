fn main() {
    println!("cargo::rustc-check-cfg=cfg(optimized)");
    println!("cargo::rerun-if-env-changed=OPT_LEVEL");

    let level = std::env::var("OPT_LEVEL").unwrap_or_default();

    if level != "0" {
        println!("cargo::rustc-cfg=optimized");
    }
}
