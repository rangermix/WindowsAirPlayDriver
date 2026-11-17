use std::io::{self, Read};

use clap::Parser;
use winairplay_service::credentials::CredentialStore;
use zeroize::Zeroizing;

const MAX_STDIN_BYTES: u64 = 1_026;

#[derive(Debug, Parser)]
#[command(about = "Install or remove a receiver password in machine-protected DPAPI storage")]
struct Arguments {
    /// Canonical twelve-hex-digit RAOP receiver identity.
    #[arg(long)]
    receiver: String,

    /// Read one password from standard input; avoids command-line disclosure.
    #[arg(long, conflicts_with = "remove", required_unless_present = "remove")]
    password_stdin: bool,

    /// Remove the protected password for this receiver.
    #[arg(long, conflicts_with = "password_stdin")]
    remove: bool,
}

fn run(arguments: &Arguments) -> Result<(), String> {
    let store = CredentialStore::default_store().map_err(|error| error.to_string())?;
    if arguments.remove {
        let removed = store
            .remove(&arguments.receiver)
            .map_err(|error| error.to_string())?;
        println!(
            "{} protected credential for receiver {}.",
            if removed { "Removed" } else { "No" },
            arguments.receiver
        );
        return Ok(());
    }

    let mut bytes = Zeroizing::new(Vec::new());
    io::stdin()
        .take(MAX_STDIN_BYTES)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("reading password from standard input: {error}"))?;
    while matches!(bytes.last(), Some(b'\r' | b'\n')) {
        bytes.pop();
    }
    let password =
        std::str::from_utf8(&bytes).map_err(|_| "password input is not valid UTF-8".to_owned())?;
    store
        .write(&arguments.receiver, password)
        .map_err(|error| error.to_string())?;
    println!(
        "Installed a machine-protected credential for receiver {}. Restart the service to reconcile immediately.",
        arguments.receiver
    );
    Ok(())
}

fn main() {
    let arguments = Arguments::parse();
    if let Err(error) = run(&arguments) {
        eprintln!("credential-store: {error}");
        std::process::exit(1);
    }
}
