use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    if let Err(error) = configure() {
        panic!("metask-agentcore-sys: {error}");
    }
}

fn configure() -> Result<(), String> {
    println!("cargo:rerun-if-env-changed=METASK_AGENTCORE_BUNDLE_DIR");
    let manifest_dir = PathBuf::from(required_env("CARGO_MANIFEST_DIR")?);
    let bundle_root = match env::var_os("METASK_AGENTCORE_BUNDLE_DIR") {
        Some(path) => PathBuf::from(path),
        None => manifest_dir.join("../.."),
    };
    let config_path = bundle_root.join("bindings/rust/link.cfg");
    println!("cargo:rerun-if-changed={}", config_path.display());
    let config = fs::read_to_string(&config_path)
        .map_err(|error| format!("cannot read {}: {error}", config_path.display()))?;
    let cargo_target = required_env("TARGET")?;
    let link_directives = parse_link_config(&config, &cargo_target)?;

    let library_file = if cargo_target.contains("windows") {
        "metask_agentcore.lib"
    } else {
        "libmetask_agentcore.a"
    };
    let library_path = bundle_root.join("lib").join(library_file);
    if !library_path.is_file() {
        return Err(format!("missing static library {}", library_path.display()));
    }
    println!(
        "cargo:rustc-link-search=native={}",
        library_path.parent().unwrap().display()
    );
    // Unix bundles already use the conventional `lib<name>.a` spelling, so
    // pass the logical library name. Using `+verbatim` there makes the crate's
    // own unit-test link emit `-llibmetask_agentcore.a` on Apple ld. Windows
    // bundles deliberately publish the exact `.lib` filename instead.
    if cargo_target.contains("windows") {
        println!("cargo:rustc-link-lib=static:+verbatim={library_file}");
    } else {
        println!("cargo:rustc-link-lib=static=metask_agentcore");
    }
    for (kind, name) in link_directives {
        match kind {
            "library" => println!("cargo:rustc-link-lib={name}"),
            "framework" => println!("cargo:rustc-link-lib=framework={name}"),
            _ => unreachable!(),
        }
    }
    Ok(())
}

fn required_env(name: &str) -> Result<String, String> {
    env::var(name).map_err(|_| format!("required environment variable {name} is missing"))
}

fn parse_link_config<'a>(
    config: &'a str,
    cargo_target: &str,
) -> Result<Vec<(&'a str, &'a str)>, String> {
    let mut lines = config.lines();
    let bundle_target = lines
        .next()
        .and_then(|line| line.strip_prefix("target="))
        .filter(|target| valid_name(target))
        .ok_or_else(|| "invalid or missing target in bindings/rust/link.cfg".to_owned())?;
    if cargo_target != bundle_target {
        return Err(format!(
            "bundle target mismatch: Cargo TARGET={cargo_target}, bundle target={bundle_target}"
        ));
    }

    let mut directives = Vec::new();
    for (index, line) in lines.enumerate() {
        let (kind, name) = line
            .split_once('=')
            .filter(|(_, name)| valid_name(name))
            .ok_or_else(|| format!("invalid link.cfg line {}", index + 2))?;
        match kind {
            "library" | "framework" => directives.push((kind, name)),
            _ => return Err(format!("unknown link.cfg directive {kind}")),
        }
    }
    Ok(directives)
}

fn valid_name(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_target_and_link_directives() {
        assert!(parse_link_config(
            "target=x86_64-pc-windows-msvc\nlibrary=advapi32\nlibrary=crypt32\n",
            "x86_64-pc-windows-msvc",
        )
        .is_ok());
    }

    #[test]
    fn rejects_wrong_target_and_malformed_directives() {
        assert!(parse_link_config("target=aarch64-apple-darwin\n", "x86_64-apple-darwin").is_err());
        assert!(parse_link_config(
            "target=x86_64-apple-darwin\nunknown=value\n",
            "x86_64-apple-darwin"
        )
        .is_err());
        assert!(parse_link_config(
            "target=x86_64-apple-darwin\nlibrary=bad name\n",
            "x86_64-apple-darwin"
        )
        .is_err());
    }
}
