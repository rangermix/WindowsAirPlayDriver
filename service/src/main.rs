use std::time::Duration;

use clap::Parser;

#[derive(Debug, Parser)]
#[command(about = "WinAirPlayAudio receiver discovery and endpoint service")]
struct Arguments {
    /// Run interactively instead of registering with the Service Control Manager.
    #[arg(long)]
    console: bool,

    /// Stop a console run after this many seconds (diagnostic/test use).
    #[arg(long, requires = "console")]
    run_for_seconds: Option<u64>,
}

fn main() {
    let arguments = Arguments::parse();
    if let Err(error) = winairplay_service::logging::initialize(arguments.console) {
        eprintln!("WinAirPlayAudioService: logging initialization failed: {error}");
    }

    let result = if arguments.console {
        winairplay_service::runtime::run_console(arguments.run_for_seconds.map(Duration::from_secs))
    } else {
        winairplay_service::runtime::run_service_dispatcher()
    };
    if let Err(error) = result {
        tracing::error!(component = "service", operation = "main", %error);
        eprintln!("WinAirPlayAudioService: startup failed: {error}");
        std::process::exit(1);
    }
}
