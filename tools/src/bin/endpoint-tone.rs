use std::time::Duration;

use clap::Parser;
use uuid::Uuid;
use winairplay_service::wasapi::render_test_tone;

#[derive(Debug, Parser)]
#[command(about = "Render a deterministic tone to one exact endpoint container")]
struct Arguments {
    /// Deterministic receiver container ID reported by endpoint-list.
    #[arg(long)]
    container_id: Uuid,

    /// Tone frequency in hertz.
    #[arg(long, default_value_t = 997.0)]
    frequency: f64,

    /// Tone duration in seconds.
    #[arg(long, default_value_t = 3.0)]
    duration: f64,

    /// Peak amplitude from zero through one.
    #[arg(long, default_value_t = 0.25)]
    amplitude: f32,
}

fn main() {
    let arguments = Arguments::parse();
    if !arguments.duration.is_finite() || arguments.duration <= 0.0 || arguments.duration > 300.0 {
        eprintln!("endpoint-tone: duration must be greater than zero and at most 300 seconds");
        std::process::exit(2);
    }
    if let Err(error) = render_test_tone(
        arguments.container_id,
        arguments.frequency,
        Duration::from_secs_f64(arguments.duration),
        arguments.amplitude,
    ) {
        eprintln!("endpoint-tone: {error}");
        std::process::exit(1);
    }
}
