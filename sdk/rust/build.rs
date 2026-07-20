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
    let manifest_path = bundle_root.join("manifest.json");
    println!("cargo:rerun-if-changed={}", manifest_path.display());
    let manifest = fs::read_to_string(&manifest_path)
        .map_err(|error| format!("cannot read {}: {error}", manifest_path.display()))?;

    require_json_u32(&manifest, "schema_version", 1)?;
    require_json_string(&manifest, "vendor", "metask")?;
    require_json_string(&manifest, "name", "agentcore")?;
    let bundle_target = json_string(&manifest, "rust_target")?;
    let cargo_target = required_env("TARGET")?;
    if cargo_target != bundle_target {
        return Err(format!(
            "bundle target mismatch: Cargo TARGET={cargo_target}, manifest target.rust_target={bundle_target}"
        ));
    }

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
    println!("cargo:rustc-link-lib=static=metask_agentcore");
    for library in json_string_array(&manifest, "system_libraries")? {
        println!("cargo:rustc-link-lib={library}");
    }
    for framework in json_string_array(&manifest, "system_frameworks")? {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
    Ok(())
}

fn required_env(name: &str) -> Result<String, String> {
    env::var(name).map_err(|_| format!("required environment variable {name} is missing"))
}

fn require_json_string(json: &str, field: &str, expected: &str) -> Result<(), String> {
    let actual = json_string(json, field)?;
    if actual == expected {
        Ok(())
    } else {
        Err(format!("manifest {field} must be {expected}, got {actual}"))
    }
}

fn require_json_u32(json: &str, field: &str, expected: u32) -> Result<(), String> {
    let value = json_value_start(json, field)?;
    let end = value
        .find(|byte: char| !byte.is_ascii_digit())
        .unwrap_or(value.len());
    if end == 0 {
        return Err(format!("manifest {field} is not an unsigned integer"));
    }
    let actual = value[..end]
        .parse::<u32>()
        .map_err(|_| format!("manifest {field} is outside the u32 range"))?;
    if actual == expected {
        Ok(())
    } else {
        Err(format!("manifest {field} must be {expected}, got {actual}"))
    }
}

fn json_string<'a>(json: &'a str, field: &str) -> Result<&'a str, String> {
    let value = json_value_start(json, field)?;
    let rest = value
        .strip_prefix('"')
        .ok_or_else(|| format!("manifest {field} is not a string"))?;
    let end = rest
        .find('"')
        .ok_or_else(|| format!("manifest {field} has an unterminated string"))?;
    let result = &rest[..end];
    if result.contains('\\') {
        return Err(format!("manifest {field} contains an unsupported escape"));
    }
    Ok(result)
}

fn json_string_array<'a>(json: &'a str, field: &str) -> Result<Vec<&'a str>, String> {
    let value = json_value_start(json, field)?;
    let mut rest = value
        .strip_prefix('[')
        .ok_or_else(|| format!("manifest {field} is not an array"))?;
    let mut values = Vec::new();
    loop {
        rest = rest.trim_start();
        if rest.starts_with(']') {
            return Ok(values);
        }
        let string = rest
            .strip_prefix('"')
            .ok_or_else(|| format!("manifest {field} contains a non-string"))?;
        let end = string
            .find('"')
            .ok_or_else(|| format!("manifest {field} has an unterminated string"))?;
        let value = &string[..end];
        if value.contains('\\') {
            return Err(format!("manifest {field} contains an unsupported escape"));
        }
        values.push(value);
        rest = string[end + 1..].trim_start();
        if let Some(next) = rest.strip_prefix(',') {
            rest = next.trim_start();
            if !rest.starts_with('"') {
                return Err(format!("manifest {field} has invalid array syntax"));
            }
        } else if rest.starts_with(']') {
            return Ok(values);
        } else {
            return Err(format!("manifest {field} has invalid array syntax"));
        }
    }
}

fn json_value_start<'a>(json: &'a str, field: &str) -> Result<&'a str, String> {
    let needle = format!("\"{field}\"");
    let start = json
        .find(&needle)
        .ok_or_else(|| format!("manifest field {field} is missing"))?;
    if json[start + needle.len()..].contains(&needle) {
        return Err(format!("manifest field {field} is duplicated"));
    }
    let tail = &json[start + needle.len()..];
    let tail = tail.trim_start();
    let value = tail
        .strip_prefix(':')
        .ok_or_else(|| format!("manifest field {field} has no value"))?;
    Ok(value.trim_start())
}

#[cfg(test)]
mod tests {
    use super::*;

    const MANIFEST: &str = r#"{
      "vendor":"metask",
      "name":"agentcore",
      "schema_version":1,
      "rust_target":"x86_64-pc-windows-msvc",
      "system_libraries":["advapi32","crypt32"],
      "system_frameworks":[]
    }"#;

    #[test]
    fn extracts_target_and_link_arrays() {
        assert_eq!(
            json_string(MANIFEST, "rust_target").unwrap(),
            "x86_64-pc-windows-msvc"
        );
        assert_eq!(
            json_string_array(MANIFEST, "system_libraries").unwrap(),
            ["advapi32", "crypt32"]
        );
        assert!(json_string_array(MANIFEST, "system_frameworks")
            .unwrap()
            .is_empty());
        assert!(require_json_u32(MANIFEST, "schema_version", 1).is_ok());
    }

    #[test]
    fn rejects_wrong_type_and_missing_field() {
        assert!(json_string(r#"{"rust_target":[]}"#, "rust_target").is_err());
        assert!(json_string(MANIFEST, "missing").is_err());
        assert!(json_string(r#"{"rust_target":"a","rust_target":"b"}"#, "rust_target").is_err());
        assert!(json_string_array(r#"{"items":["a",]}"#, "items").is_err());
    }
}
