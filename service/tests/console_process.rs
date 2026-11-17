use std::fs;
use std::process::Command;

#[test]
fn observe_only_console_service_starts_and_stops_cleanly() {
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let program_data = std::env::temp_dir().join(format!(
        "winairplay-console-test-{}-{unique}",
        std::process::id()
    ));
    let config_directory = program_data.join("WinAirPlayAudio");
    fs::create_dir_all(&config_directory).unwrap();
    fs::write(
        config_directory.join("config.json"),
        br#"{"manage_endpoints":false}"#,
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_WinAirPlayAudioService"))
        .args(["--console", "--run-for-seconds", "1"])
        .env("ProgramData", &program_data)
        .env("RUST_LOG", "winairplay_service=info")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "service failed\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let logs = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        logs.contains("\"component\":\"service\""),
        "service emitted no structured lifecycle log:\n{logs}"
    );
    fs::remove_dir_all(program_data).unwrap();
}
