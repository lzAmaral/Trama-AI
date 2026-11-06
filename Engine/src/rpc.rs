use base64::{Engine as _, engine::general_purpose::STANDARD};
use orkai::{
    cli::{self, Probe},
    client,
    config::Config,
    launch::{LaunchMode, Launcher},
    model::{AgentKind, AgentRecord, NewAgent},
    paths::Home,
    protocol::{ClientMsg, TermSize},
    skills,
    store::Store,
    usage, worktree,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    fs::{File, OpenOptions},
    io::{self, Read},
    os::fd::AsRawFd,
    os::unix::fs::OpenOptionsExt,
    path::PathBuf,
    process::ExitCode,
    thread,
    time::{Duration, Instant},
};

pub const OPERATIONS: &[&str] = &[
    "inspect",
    "list",
    "start",
    "input",
    "snapshot",
    "resize",
    "stop",
    "resume",
    "create_session",
    "skills",
    "diff",
    "merge",
    "details",
    "logs",
    "usage",
    "remove",
];
const MAX_REQUEST: u64 = 65_536;
const MAX_RESULT: usize = 900_000;
const MAX_AGENTS: usize = 64;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    operation: String,
    agent_id: Option<u32>,
    kind: Option<String>,
    cwd: Option<String>,
    name: Option<String>,
    task: Option<String>,
    session: Option<String>,
    isolate: Option<bool>,
    input: Option<String>,
    rows: Option<u16>,
    cols: Option<u16>,
    message: Option<String>,
    confirmed: Option<bool>,
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

pub fn serve(home: io::Result<PathBuf>) -> ExitCode {
    let result = (|| {
        let home = home?;
        let mut bytes = Vec::new();
        io::stdin().take(MAX_REQUEST + 1).read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_REQUEST {
            return Err(invalid("request exceeds 64 KiB"));
        }
        let request: Request =
            serde_json::from_slice(&bytes).map_err(|_| invalid("invalid request JSON"))?;
        dispatch(home, request)
    })();
    let reply = match result {
        Ok(result) => json!({"protocol":1, "ok":true, "result":result}),
        Err(error) => json!({"protocol":1, "ok":false, "error":public_error(&error)}),
    };
    match serde_json::to_vec(&reply) {
        Ok(bytes) if bytes.len() <= MAX_RESULT => {
            use std::io::Write;
            if io::stdout().write_all(&bytes).is_ok() {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        }
        _ => {
            let _ = serde_json::to_writer(
                io::stdout(),
                &json!({"protocol":1,"ok":false,"error":"response exceeds size limit"}),
            );
            ExitCode::SUCCESS
        }
    }
}

fn public_error(error: &io::Error) -> String {
    // Only our validation strings and known categories leave the process. Git/CLI stderr may contain secrets.
    if error.kind() == io::ErrorKind::InvalidInput {
        return error.to_string();
    }
    match error.kind() {
        io::ErrorKind::NotFound => "The requested resource or provider executable was not found.",
        io::ErrorKind::AlreadyExists => "This name already exists.",
        io::ErrorKind::WouldBlock => {
            "Another operation is modifying the engine. Try again after it finishes."
        }
        io::ErrorKind::TimedOut => {
            "The engine operation timed out; check the current state before retrying."
        }
        io::ErrorKind::PermissionDenied => "The operation was denied.",
        _ => "The engine could not complete the operation. Check the project and agent state.",
    }
    .into()
}

struct MutationLock(File);
impl MutationLock {
    fn acquire(home: &Home) -> io::Result<Self> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(home.root().join("trama-mutation.lock"))?;
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                return Ok(Self(file));
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::WouldBlock || Instant::now() >= deadline {
                return Err(error);
            }
            thread::sleep(Duration::from_millis(20));
        }
    }
}
impl Drop for MutationLock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

fn directory(value: Option<&str>) -> io::Result<PathBuf> {
    let path = PathBuf::from(value.ok_or_else(|| invalid("cwd is required"))?);
    if !path.is_absolute() || !path.is_dir() {
        return Err(invalid("cwd must be an existing absolute directory"));
    }
    path.canonicalize()
}

fn size(request: &Request) -> io::Result<TermSize> {
    let (rows, cols) = (request.rows.unwrap_or(40), request.cols.unwrap_or(120));
    if !(2..=100).contains(&rows) || !(10..=240).contains(&cols) {
        return Err(invalid(
            "terminal size must be 2..100 rows and 10..240 columns",
        ));
    }
    Ok(TermSize::new(rows, cols))
}

fn provider(value: Option<&str>) -> io::Result<AgentKind> {
    AgentKind::parse(value.ok_or_else(|| invalid("kind is required"))?)
        .ok_or_else(|| invalid("unknown provider"))
}

fn dispatch(home: PathBuf, request: Request) -> io::Result<Value> {
    if !OPERATIONS.contains(&request.operation.as_str()) || request.operation == "inspect" {
        return Err(invalid("unsupported operation"));
    }
    let store = Store::open(Home::at(home))?;
    let mutation = matches!(
        request.operation.as_str(),
        "start" | "stop" | "resume" | "create_session" | "merge" | "remove"
    );
    let _lock = if mutation {
        Some(MutationLock::acquire(store.home())?)
    } else {
        None
    };
    match request.operation.as_str() {
        "list" => list(&store),
        "usage" => {
            if request.confirmed != Some(true) {
                return Err(invalid("explicit usage confirmation is required"));
            }
            let kind = provider(request.kind.as_deref())?;
            if !usage::PROVIDERS.contains(&kind) {
                return Err(invalid("usage is unsupported for this provider"));
            }
            let (limits, problem) = match usage::fetch(kind, &Config::default()) {
                Ok(limits) => (
                    Some(
                        json!({"session":window(limits.session),"weekly":window(limits.weekly),
                    "monthly":window(limits.monthly),"credits":limits.credits}),
                    ),
                    None,
                ),
                Err(problem) => (None, Some(problem.label())),
            };
            Ok(
                json!({"kind":kind.label(),"limits":limits,"problem":problem,"updatedAtMs":orkai::util::now_ms()}),
            )
        }
        "start" => {
            if store.list_agents()?.len() >= MAX_AGENTS {
                return Err(invalid("this version supports at most 64 stored agents"));
            }
            let name = request
                .name
                .as_deref()
                .ok_or_else(|| invalid("name is required"))?;
            let draft = NewAgent {
                name: name.into(),
                kind: provider(request.kind.as_deref())?,
                cwd: directory(request.cwd.as_deref())?,
                task: request.task.clone().unwrap_or_default(),
                session: request.session.clone().unwrap_or_else(|| "default".into()),
            };
            let existing = store.list_agents()?;
            let sessions = store.peek_sessions_with(&existing)?.0;
            if !sessions.iter().any(|s| s.name == draft.session) {
                return Err(invalid("session does not exist; create it first"));
            }
            if existing
                .iter()
                .any(|r| r.session == draft.session && r.name == draft.name)
            {
                return Err(invalid("agent name already exists in this session"));
            }
            let launcher = Launcher::new(store, Config::default(), &std::env::current_exe()?)?;
            let record = launcher.create(
                draft,
                size(&request)?,
                request.isolate.unwrap_or(false),
                false,
                false,
            )?;
            wait_for_holder(launcher.store(), record.id)?;
            Ok(json!({"agentId":record.id}))
        }
        "create_session" => {
            let name = request
                .session
                .as_deref()
                .ok_or_else(|| invalid("session is required"))?;
            let session = store.create_session(name)?;
            Ok(json!({"session":session.name}))
        }
        "skills" => {
            let cwd = directory(request.cwd.as_deref())?;
            let kind = provider(request.kind.as_deref())?;
            let entries: Vec<Value> = skills::discover(kind, &cwd)
                .iter()
                .map(|skill| {
                    json!({
                        "name":skill.name, "description":format!("{} skill", skill.owner.label()),
                        "invocation":skills::invocation(kind, skill, "")
                    })
                })
                .collect();
            Ok(json!({"skills":entries}))
        }
        _ => agent_action(store, request),
    }
}

fn list(store: &Store) -> io::Result<Value> {
    let records = store.list_agents()?;
    if records.len() > MAX_AGENTS {
        return Err(invalid("this version supports at most 64 stored agents"));
    }
    let sessions = store
        .peek_sessions_with(&records)?
        .0
        .into_iter()
        .map(|s| s.name)
        .collect::<Vec<_>>();
    // Each connect/probe has upstream deadlines; parallelism is bounded by MAX_AGENTS.
    let agents: Vec<Value> = thread::scope(|scope| {
        let jobs = records
            .iter()
            .map(|record| scope.spawn(|| describe(store, record)))
            .collect::<Vec<_>>();
        jobs.into_iter()
            .map(|job| job.join().map_err(|_| io::Error::other("probe failed")))
            .collect::<io::Result<Vec<_>>>()
    })?;
    Ok(json!({"agents":agents,"sessions":sessions}))
}

fn describe(store: &Store, record: &AgentRecord) -> Value {
    let probe = cli::probe(store, record.id);
    let (kind, activity, nested) = match &probe {
        Probe::Live(status) => (
            status.running_kind(record.kind),
            status.activity.clone(),
            serde_json::to_value(&status.nested).unwrap_or(Value::Null),
        ),
        Probe::Exited(exit) => (record.kind, exit.describe(), Value::Null),
        Probe::Lost => (record.kind, "Session interrupted".into(), Value::Null),
    };
    json!({"id":record.id,"name":record.name,"kind":kind.label(),"state":probe.state().label(),
           "session":record.session,"cwd":record.cwd,"project":record.project_dir(),"task":record.task,
           "activity":activity,"branch":record.worktree.as_ref().map(|w| &w.branch), "nested":nested})
}

fn wait_for_holder(store: &Store, id: u32) -> io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        // An immediately exited command is also a completed launch, retained for diagnostics.
        if store.read_runtime(id)?.is_some() || store.read_exit(id)?.is_some() {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "holder startup timed out",
            ));
        }
        thread::sleep(Duration::from_millis(20));
    }
}

fn window(value: Option<usage::Window>) -> Value {
    value
        .map(|w| json!({"usedPercent":w.used_percent,"resetsAtMs":w.resets_at_ms}))
        .unwrap_or(Value::Null)
}

fn agent_action(store: Store, request: Request) -> io::Result<Value> {
    let id = request
        .agent_id
        .ok_or_else(|| invalid("agentId is required"))?;
    let mut record = store.load_agent(id)?;
    match request.operation.as_str() {
        "input" | "resize" => {
            let message = if request.operation == "input" {
                let input = STANDARD
                    .decode(
                        request
                            .input
                            .as_deref()
                            .ok_or_else(|| invalid("input is required"))?,
                    )
                    .map_err(|_| invalid("input must be base64"))?;
                if input.len() > 32_768 {
                    return Err(invalid("input exceeds 32 KiB"));
                }
                ClientMsg::Input(input)
            } else {
                ClientMsg::Resize(size(&request)?)
            };
            let runtime = store
                .read_runtime(id)?
                .ok_or_else(|| invalid("agent is not running"))?;
            if request.operation == "resize" {
                let (connection, reader, _) = client::connect(&runtime)?;
                connection.send(&ClientMsg::Attach(size(&request)?))?;
                connection.send(&message)?;
                connection.finish(reader)?;
            } else {
                client::deliver(&runtime, &message)?;
            }
            Ok(json!({}))
        }
        "details" => {
            let status = match cli::probe(&store, id) {
                Probe::Live(status) => serde_json::to_value(status)?,
                _ => Value::Null,
            };
            Ok(json!({"agent":describe(&store, &record),"status":status}))
        }
        "logs" => {
            // Upstream uses a framed binary operation log; replay it instead of exposing binary records.
            let path = store.home().output_log(id);
            for candidate in [&path, &orkai::holder::oplog::rotated_path(&path)] {
                if let Ok(metadata) = std::fs::metadata(candidate) {
                    if metadata.len() > 16 * 1024 * 1024 {
                        return Err(invalid("recorded log exceeds replay limit"));
                    }
                }
            }
            let text = cli::transcript(&store, id)?.unwrap_or_default().join("\n");
            let mut start = text.len().saturating_sub(65_536);
            while !text.is_char_boundary(start) {
                start += 1;
            }
            Ok(json!({"text":&text[start..],"truncated":start > 0}))
        }
        "snapshot" => {
            let runtime = store
                .read_runtime(id)?
                .ok_or_else(|| invalid("agent is not running"))?;
            let snapshot = client::peek(&runtime)?;
            if snapshot.data.len() > 512_000 {
                return Err(invalid("snapshot exceeds size limit"));
            }
            Ok(
                json!({"data":STANDARD.encode(snapshot.data),"rows":snapshot.size.rows,"cols":snapshot.size.cols}),
            )
        }
        "stop" => {
            cli::stop(&store, id)?;
            Ok(json!({}))
        }
        "resume" => {
            if !matches!(cli::probe(&store, id), Probe::Lost) {
                return Err(invalid("only interrupted sessions can be resumed"));
            }
            let launcher = Launcher::new(store, Config::default(), &std::env::current_exe()?)?;
            launcher.start(&mut record, LaunchMode::Resume, size(&request)?)?;
            wait_for_holder(launcher.store(), id)?;
            Ok(json!({"agentId":id}))
        }
        "diff" => {
            let data = match &record.worktree {
                Some(worktree) => worktree::diff(worktree)?,
                None => worktree::pending_diff(&worktree::folder(&record.cwd)?)?,
            };
            if data.len() > 512_000 {
                return Err(invalid("diff exceeds size limit"));
            }
            Ok(json!({"text":String::from_utf8_lossy(&data)}))
        }
        "remove" => {
            if request.confirmed != Some(true) {
                return Err(invalid("explicit removal confirmation is required"));
            }
            if !matches!(cli::probe(&store, id), Probe::Exited(_)) {
                return Err(invalid("only exited agents can be removed"));
            }
            if record.worktree.is_some() {
                return Err(invalid(
                    "agents with isolated worktrees cannot be removed in this version",
                ));
            }
            store.remove_agent(id)?;
            Ok(json!({}))
        }
        "merge" => {
            if request.confirmed != Some(true) {
                return Err(invalid("explicit merge confirmation is required"));
            }
            // A holder can resume writing even after an idle/done snapshot. Require it fully stopped.
            if !matches!(cli::probe(&store, id), Probe::Exited(_)) {
                return Err(invalid("stop the agent before merging its worktree"));
            }
            let worktree = record
                .worktree
                .as_ref()
                .ok_or_else(|| invalid("agent has no isolated worktree"))?;
            let message = request
                .message
                .as_deref()
                .filter(|s| !s.trim().is_empty())
                .ok_or_else(|| invalid("merge message is required"))?;
            let merged = worktree::merge(worktree, message)?;
            Ok(json!({"message":format!("Merged into {}",merged.target)}))
        }
        _ => Err(invalid("unsupported operation")),
    }
}
