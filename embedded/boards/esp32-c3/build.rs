// Shared with the S3 app — emits the linkall.x linker invocation that
// esp-hal expects, and prints helpful hints when the linker fails.

fn main() {
    // Must be last so flip-link / linker scripts work correctly.
    println!("cargo:rustc-link-arg=-Tlinkall.x");
}
