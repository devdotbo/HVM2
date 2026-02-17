use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn render_blob_header(bytes: &[u8]) -> String {
  let mut out = String::new();
  out.push_str("#pragma once\n\n");
  out.push_str("static const unsigned char HVM_METAL_LIB[] = {");
  for (i, b) in bytes.iter().enumerate() {
    if i % 12 == 0 {
      out.push_str("\n  ");
    }
    out.push_str(&format!("0x{:02X}, ", b));
  }
  out.push_str("\n};\n");
  out.push_str(&format!("static const unsigned int HVM_METAL_LIB_LEN = {};\n", bytes.len()));
  out
}

fn run_checked(mut cmd: Command, what: &str) -> Result<(), String> {
  let output = cmd
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .output()
    .map_err(|e| format!("failed to run {what}: {e}"))?;

  if output.status.success() {
    Ok(())
  } else {
    let stderr = String::from_utf8_lossy(&output.stderr);
    let stdout = String::from_utf8_lossy(&output.stdout);
    Err(format!("{what} failed:\n{stdout}\n{stderr}"))
  }
}

fn compile_metal_lib(out_dir: &Path) -> Result<(), String> {
  let air_path = out_dir.join("hvm.air");
  let metallib_path = out_dir.join("hvm.metallib");
  let header_path = out_dir.join("hvm_metal_lib.h");

  run_checked(
    {
      let mut cmd = Command::new("xcrun");
      cmd.args([
        "--sdk",
        "macosx",
        "metal",
        "-O3",
        "-c",
        "src/hvm.metal",
        "-o",
      ])
      .arg(&air_path);
      cmd
    },
    "xcrun metal",
  )?;

  run_checked(
    {
      let mut cmd = Command::new("xcrun");
      cmd.args(["--sdk", "macosx", "metallib"])
        .arg(&air_path)
        .arg("-o")
        .arg(&metallib_path);
      cmd
    },
    "xcrun metallib",
  )?;

  let bytes = fs::read(&metallib_path)
    .map_err(|e| format!("failed to read generated metallib '{}': {e}", metallib_path.display()))?;

  fs::write(&header_path, render_blob_header(&bytes))
    .map_err(|e| format!("failed to write header '{}': {e}", header_path.display()))?;

  Ok(())
}

fn main() {
  let cores = num_cpus::get();
  let tpcl2 = (cores as f64).log2().floor() as u32;

  println!("cargo:rerun-if-changed=src/run.c");
  println!("cargo:rerun-if-changed=src/hvm.c");
  println!("cargo:rerun-if-changed=src/run.cu");
  println!("cargo:rerun-if-changed=src/hvm.cu");
  println!("cargo:rerun-if-changed=src/run.metal.mm");
  println!("cargo:rerun-if-changed=src/hvm.metal");
  println!("cargo:rustc-link-arg=-rdynamic");

  match cc::Build::new()
    .file("src/run.c")
    .opt_level(3)
    .warnings(false)
    .define("TPC_L2", &*tpcl2.to_string())
    .define("IO", None)
    .try_compile("hvm-c")
  {
    Ok(_) => println!("cargo:rustc-cfg=feature=\"c\""),
    Err(e) => {
      println!("cargo:warning=\x1b[1m\x1b[31mWARNING: Failed to compile/run.c:\x1b[0m {}", e);
      println!("cargo:warning=Ignoring/run.c and proceeding with build. \x1b[1mThe C runtime will not be available.\x1b[0m");
    }
  }

  if Command::new("nvcc")
    .arg("--version")
    .stdout(Stdio::null())
    .stderr(Stdio::null())
    .status()
    .is_ok()
  {
    if let Ok(cuda_path) = env::var("CUDA_HOME") {
      println!("cargo:rustc-link-search=native={}/lib64", cuda_path);
    } else {
      println!("cargo:rustc-link-search=native=/usr/local/cuda/lib64");
    }

    cc::Build::new()
      .cuda(true)
      .file("src/run.cu")
      .define("IO", None)
      .flag("-diag-suppress=177")
      .flag("-diag-suppress=550")
      .flag("-diag-suppress=20039")
      .compile("hvm-cu");

    println!("cargo:rustc-cfg=feature=\"cuda\"");
  } else {
    println!("cargo:warning=\x1b[1m\x1b[31mWARNING: CUDA compiler not found.\x1b[0m \x1b[1mHVM will not be able to run on GPU.\x1b[0m");
  }

  if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
    let has_metal_toolchain = Command::new("xcrun")
      .args(["--sdk", "macosx", "metal", "-v"])
      .stdout(Stdio::null())
      .stderr(Stdio::null())
      .status()
      .is_ok();

    if has_metal_toolchain {
      println!("cargo:rustc-link-lib=framework=Foundation");
      println!("cargo:rustc-link-lib=framework=Metal");

      let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is always set by Cargo"));
      match compile_metal_lib(&out_dir) {
        Ok(_) => {
          match cc::Build::new()
            .cpp(true)
            .file("src/run.metal.mm")
            .include(&out_dir)
            .flag("-std=c++17")
            .flag("-fobjc-arc")
            .warnings(false)
            .try_compile("hvm-metal")
          {
            Ok(_) => println!("cargo:rustc-cfg=feature=\"metal\""),
            Err(e) => {
              println!("cargo:warning=\x1b[1m\x1b[31mWARNING: Failed to compile/run.metal.mm:\x1b[0m {}", e);
              println!("cargo:warning=Ignoring/run.metal.mm and proceeding with build. \x1b[1mThe Metal runtime will not be available.\x1b[0m");
            }
          }
        }
        Err(e) => {
          println!("cargo:warning=\x1b[1m\x1b[31mWARNING: Failed to compile Metal kernel library:\x1b[0m {}", e.replace('\n', " "));
          println!("cargo:warning=Ignoring Metal runtime and proceeding with build. \x1b[1mThe Metal runtime will not be available.\x1b[0m");
        }
      }
    } else {
      println!("cargo:warning=\x1b[1m\x1b[31mWARNING: Metal toolchain not found.\x1b[0m \x1b[1mHVM will not be able to run on Metal.\x1b[0m");
    }
  }
}
