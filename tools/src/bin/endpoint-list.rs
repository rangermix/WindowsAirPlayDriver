use clap::Parser;
use serde::Serialize;
use uuid::Uuid;
use winairplay_service::wasapi::list_render_endpoints;

#[derive(Debug, Parser)]
#[command(about = "List active Windows render endpoints and their container mappings")]
struct Arguments {
    /// Emit a JSON array rather than readable rows.
    #[arg(long)]
    json: bool,

    /// Restrict output to one deterministic receiver container ID.
    #[arg(long)]
    container_id: Option<Uuid>,
}

#[derive(Serialize)]
struct EndpointOutput<'a> {
    endpoint_id: &'a str,
    friendly_name: &'a str,
    container_id: Option<String>,
    receiver_id: Option<&'a str>,
}

fn run(arguments: &Arguments) -> Result<(), String> {
    let endpoints = list_render_endpoints().map_err(|error| error.to_string())?;
    let filtered = endpoints
        .iter()
        .filter(|endpoint| {
            arguments
                .container_id
                .is_none_or(|expected| endpoint.container_id == Some(expected))
        })
        .collect::<Vec<_>>();

    if arguments.json {
        let output = filtered
            .iter()
            .map(|endpoint| EndpointOutput {
                endpoint_id: &endpoint.endpoint_id,
                friendly_name: &endpoint.friendly_name,
                container_id: endpoint.container_id.map(|value| value.to_string()),
                receiver_id: endpoint.receiver_id.as_deref(),
            })
            .collect::<Vec<_>>();
        println!(
            "{}",
            serde_json::to_string_pretty(&output)
                .map_err(|error| format!("serializing endpoint list: {error}"))?
        );
    } else if filtered.is_empty() {
        println!("No matching active render endpoints.");
    } else {
        for endpoint in filtered {
            println!(
                "{}\n  endpoint: {}\n  container: {}\n  receiver: {}",
                endpoint.friendly_name,
                endpoint.endpoint_id,
                endpoint
                    .container_id
                    .map_or_else(|| "<none>".to_owned(), |value| value.to_string()),
                endpoint.receiver_id.as_deref().unwrap_or("<none>")
            );
        }
    }
    Ok(())
}

fn main() {
    let arguments = Arguments::parse();
    if let Err(error) = run(&arguments) {
        eprintln!("endpoint-list: {error}");
        std::process::exit(1);
    }
}
