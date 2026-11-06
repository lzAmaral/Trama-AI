use std::{env, io, path::PathBuf, process::ExitCode};

use orkai::{config::Config, launch, model::AgentKind, paths::Home, store::Store};
use serde::Serialize;

const UPSTREAM_REVISION: &str = "f66aa854313026870aaf57f65d26d9cbfbf32269";

#[derive(Serialize)]
struct Provider {
    id: &'static str,
    installed: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Inspection {
    protocol: u32,
    engine: &'static str,
    upstream_revision: &'static str,
    upstream_version: &'static str,
    providers: Vec<Provider>,
    agent_count: usize,
    operations: Vec<&'static str>,
}

fn parse_args(args: &[String]) -> io::Result<PathBuf> {
    if args.len() != 3 || args[0] != "--inspect" || args[1] != "--home" {
        return Err(io::Error::new(io::ErrorKind::InvalidInput,
            "usage: trama-engine --inspect --home ABSOLUTE_DIRECTORY"));
    }
    let home = PathBuf::from(&args[2]);
    if !home.is_absolute() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "engine home must be absolute"));
    }
    Ok(home)
}

fn inspect(home: PathBuf) -> io::Result<Inspection> {
    // Explicit Trama storage; never resolve or migrate Octo's existing home.
    let store = Store::open(Home::at(home))?;
    let config = Config::default();
    let installed = launch::installed_kinds(&config);
    Ok(Inspection {
        protocol: 1,
        engine: "octo",
        upstream_revision: UPSTREAM_REVISION,
        upstream_version: "0.2.19",
        providers: AgentKind::ALL.into_iter().map(|kind| Provider {
            id: kind.label(), installed: installed.contains(&kind),
        }).collect(),
        // Stored records, NOT a count of active processes. No holder connections here.
        agent_count: store.list_agents()?.len(),
        operations: vec!["inspect"],
    })
}

fn main() -> ExitCode {
    let result = parse_args(&env::args().skip(1).collect::<Vec<_>>()).and_then(inspect);
    match result {
        Ok(response) => match serde_json::to_writer(io::stdout().lock(), &response) {
            Ok(()) => ExitCode::SUCCESS,
            Err(_) => ExitCode::FAILURE,
        },
        Err(error) => {
            eprintln!("trama-engine: {error}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_unknown_commands_and_relative_storage() {
        for args in [vec![], vec!["--start"], vec!["--inspect", "--home", "relative"]] {
            assert!(parse_args(&args.into_iter().map(String::from).collect::<Vec<_>>()).is_err());
        }
        assert_eq!(parse_args(&["--inspect".into(), "--home".into(), "/tmp/a b".into()]).unwrap(), PathBuf::from("/tmp/a b"));
    }

    #[test]
    fn inspection_uses_upstream_registry_without_initializing_agent_config() {
        let root = env::temp_dir().join(format!("trama-engine-{}", std::process::id()));
        let response = inspect(root.clone()).unwrap();
        assert_eq!(response.providers.len(), AgentKind::ALL.len());
        assert_eq!(response.agent_count, 0);
        assert_eq!(response.operations, ["inspect"]);
        assert!(!root.join("config.json").exists());
        assert!(!root.join("agents-host.json").exists());
        assert!(root.join("agents").is_dir());
        std::fs::remove_dir_all(root).unwrap();
    }
}
