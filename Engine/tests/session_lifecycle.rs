use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

struct Fixture {
    root: PathBuf,
    ids: Vec<u64>,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "trama-rpc-{}-{}",
            std::process::id(),
            orkai::util::new_uuid_v4().unwrap()
        ));
        fs::create_dir_all(root.join("project")).unwrap();
        Self {
            root,
            ids: Vec::new(),
        }
    }
    fn home(&self) -> PathBuf {
        self.root.join("engine")
    }
    fn project(&self) -> PathBuf {
        self.root.join("project")
    }
    fn raw(&self, data: &[u8]) -> Value {
        let mut child = Command::new(env!("CARGO_BIN_EXE_trama-engine"))
            .args(["--request", "--home"])
            .arg(self.home())
            .env("SHELL", "/bin/sh")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(data).unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).unwrap()
    }
    fn request(&self, value: Value) -> Value {
        self.raw(&serde_json::to_vec(&value).unwrap())
    }
    fn ok(&self, value: Value) -> Value {
        let reply = self.request(value);
        assert_eq!(reply["ok"], true, "{reply}");
        reply["result"].clone()
    }
    fn start(&mut self, isolated: bool) -> u64 {
        let result = self.ok(json!({"operation":"start","kind":"terminal","cwd":self.project(),"name":"controlled-shell","isolate":isolated}));
        let id = result["agentId"].as_u64().unwrap();
        self.ids.push(id);
        let until = Instant::now() + Duration::from_secs(5);
        while !self
            .home()
            .join(format!("agents/{id}/runtime.json"))
            .exists()
        {
            assert!(Instant::now() < until, "holder did not start");
            thread::sleep(Duration::from_millis(20));
        }
        id
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        for id in &self.ids {
            let _ = self.request(json!({"operation":"stop","agentId":id}));
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn rejects_invalid_requests_and_forbidden_options() {
    let fixture = Fixture::new();
    for request in [
        json!({"operation":"trust"}),
        json!({"operation":"usage","kind":"codex"}),
        json!({"operation":"usage","confirmed":true}),
        json!({"operation":"usage","kind":"terminal","confirmed":true}),
        json!({"operation":"start","bypass":true}),
        json!({"operation":"start","kind":"terminal","cwd":"relative","name":"bad"}),
        json!({"operation":"start","kind":"not-a-provider","cwd":fixture.project(),"name":"bad"}),
    ] {
        assert_eq!(fixture.request(request)["ok"], false);
    }
    assert_eq!(fixture.raw(b"not json")["ok"], false);
    let oversized = vec![b' '; 65_537];
    assert_eq!(fixture.raw(&oversized)["ok"], false);
}

#[test]
fn terminal_lifecycle_survives_request_processes() {
    let mut fixture = Fixture::new();
    fixture.ok(json!({"operation":"create_session","session":"test-session"}));
    let listing = fixture.ok(json!({"operation":"list"}));
    assert!(
        listing["sessions"]
            .as_array()
            .unwrap()
            .contains(&json!("test-session"))
    );
    let id = fixture.start(false);
    let stored: Value = serde_json::from_slice(
        &fs::read(fixture.home().join(format!("agents/{id}/agent.json"))).unwrap(),
    )
    .unwrap();
    assert_eq!(stored["bypass"], false);
    assert_eq!(stored["remote_control"], false);
    fixture.ok(json!({"operation":"input","agentId":id,"input":STANDARD.encode(b"printf 'TRAMA_%s\\n' LIFECYCLE_OK\r")}));
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let snapshot = fixture.ok(json!({"operation":"snapshot","agentId":id}));
        let bytes = STANDARD.decode(snapshot["data"].as_str().unwrap()).unwrap();
        if String::from_utf8_lossy(&bytes).contains("TRAMA_LIFECYCLE_OK") {
            break;
        }
        assert!(Instant::now() < deadline, "expected terminal output");
        thread::sleep(Duration::from_millis(30));
    }
    assert_eq!(
        fixture.request(json!({"operation":"remove","agentId":id,"confirmed":true}))["ok"],
        false
    );
    fixture.ok(json!({"operation":"resize","agentId":id,"rows":30,"cols":90}));
    let snapshot = fixture.ok(json!({"operation":"snapshot","agentId":id}));
    assert_eq!(snapshot["rows"], 30);
    assert_eq!(snapshot["cols"], 90);
    let listing = fixture.ok(json!({"operation":"list"}));
    assert_eq!(listing["agents"][0]["id"], id);
    assert_ne!(listing["agents"][0]["state"], "lost");
    fixture.ok(json!({"operation":"stop","agentId":id}));
    let listing = fixture.ok(json!({"operation":"list"}));
    assert_eq!(listing["agents"][0]["state"], "exited");
    let logs = fixture.ok(json!({"operation":"logs","agentId":id}));
    assert!(
        logs["text"]
            .as_str()
            .unwrap()
            .contains("TRAMA_LIFECYCLE_OK")
    );
    let details = fixture.ok(json!({"operation":"details","agentId":id}));
    assert_eq!(details["agent"]["state"], "exited");
    assert!(details["status"].is_null());
    // Emulate a crash that lost runtime/exit markers after the controlled process stopped.
    fs::remove_file(fixture.home().join(format!("agents/{id}/exit.json"))).unwrap();
    let _ = fs::remove_file(fixture.home().join(format!("agents/{id}/runtime.json")));
    fixture.ok(json!({"operation":"resume","agentId":id}));
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let listing = fixture.ok(json!({"operation":"list"}));
        if listing["agents"][0]["state"] != "lost" {
            break;
        }
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(20));
    }
    fixture.ok(json!({"operation":"stop","agentId":id}));
    assert_eq!(
        fixture.request(json!({"operation":"remove","agentId":id}))["ok"],
        false
    );
    fixture.ok(json!({"operation":"remove","agentId":id,"confirmed":true}));
    assert!(
        fixture.ok(json!({"operation":"list"}))["agents"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(fixture.project().is_dir());
}

fn git(dir: &Path, args: &[&str]) {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn isolated_worktree_requires_stopped_agent_and_confirmation_before_merge() {
    let mut fixture = Fixture::new();
    let project = fixture.project();
    git(&project, &["init", "-b", "main"]);
    git(&project, &["config", "user.name", "Trama Test"]);
    git(
        &project,
        &["config", "user.email", "trama-test@example.invalid"],
    );
    fs::write(project.join("README.md"), "original\n").unwrap();
    git(&project, &["add", "."]);
    git(&project, &["commit", "-m", "initial"]);
    let id = fixture.start(true);
    let listing = fixture.ok(json!({"operation":"list"}));
    let worktree = PathBuf::from(listing["agents"][0]["cwd"].as_str().unwrap());
    fs::write(worktree.join("README.md"), "modified by test\n").unwrap();
    let diff = fixture.ok(json!({"operation":"diff","agentId":id}));
    assert!(diff["text"].as_str().unwrap().contains("modified by test"));
    assert_eq!(
        fixture.request(
            json!({"operation":"merge","agentId":id,"confirmed":true,"message":"test change"})
        )["ok"],
        false
    );
    fixture.ok(json!({"operation":"stop","agentId":id}));
    assert_eq!(
        fixture.request(json!({"operation":"merge","agentId":id,"message":"test change"}))["ok"],
        false
    );
    assert_eq!(
        fixture.request(json!({"operation":"remove","agentId":id,"confirmed":true}))["ok"],
        false
    );
    assert!(worktree.exists());
    fixture.ok(json!({"operation":"merge","agentId":id,"confirmed":true,"message":"test change"}));
    assert_eq!(
        fs::read_to_string(project.join("README.md")).unwrap(),
        "modified by test\n"
    );
}

#[test]
fn session_edits_require_exited_agents_and_preserve_identity() {
    let mut f = Fixture::new();
    let id = f.start(false);
    f.ok(json!({"operation":"create_session","session":"destination"}));
    for request in [
        json!({"operation":"rename_session","session":"default","name":"renamed"}),
        json!({"operation":"move_agent","agentId":id,"session":"destination"}),
    ] {
        assert_eq!(f.request(request)["ok"], false);
    }
    f.ok(json!({"operation":"stop","agentId":id}));
    f.ok(json!({"operation":"rename_session","session":"default","name":"renamed"}));
    let listing = f.ok(json!({"operation":"list"}));
    assert_eq!(listing["agents"][0]["session"], "renamed");
    assert!(
        !listing["sessions"]
            .as_array()
            .unwrap()
            .contains(&json!("default"))
    );
    for request in [
        json!({"operation":"rename_session","session":"renamed","name":"destination"}),
        json!({"operation":"rename_session","session":"missing","name":"other"}),
        json!({"operation":"rename_session","session":"renamed","name":"../invalid"}),
        json!({"operation":"move_agent","agentId":id,"session":"missing"}),
    ] {
        assert_eq!(f.request(request)["ok"], false);
    }
    f.ok(json!({"operation":"move_agent","agentId":id,"session":"destination"}));
    let listing = f.ok(json!({"operation":"list"}));
    assert_eq!(listing["agents"][0]["id"], id);
    assert_eq!(listing["agents"][0]["session"], "destination");
    assert_eq!(listing["agents"][0]["state"], "exited");
    // A destination name collision must leave both records unchanged.
    let store = orkai::store::Store::open(orkai::paths::Home::at(f.home())).unwrap();
    let other = store
        .create_agent(orkai::model::NewAgent {
            name: "controlled-shell".into(),
            kind: orkai::model::AgentKind::Terminal,
            cwd: f.project(),
            task: String::new(),
            session: "renamed".into(),
        })
        .unwrap();
    assert_eq!(
        f.request(json!({"operation":"move_agent","agentId":id,"session":"renamed"}))["ok"],
        false
    );
    assert_eq!(store.load_agent(id as u32).unwrap().session, "destination");
    assert_eq!(store.load_agent(other.id).unwrap().session, "renamed");
    // Lost is not evidence that a holder has exited; do not mutate its captured session.
    assert_eq!(
        f.request(json!({"operation":"move_agent","agentId":other.id,"session":"destination"}))["ok"],
        false
    );
    assert_eq!(
        f.request(json!({"operation":"rename_session","session":"renamed","name":"unsafe-lost"}))["ok"],
        false
    );
}

#[test]
fn metadata_edits_refuse_a_corrupt_record_without_overwriting_it() {
    let f = Fixture::new();
    let store = orkai::store::Store::open(orkai::paths::Home::at(f.home())).unwrap();
    let record = store
        .create_agent(orkai::model::NewAgent {
            name: "corrupt".into(),
            kind: orkai::model::AgentKind::Terminal,
            cwd: f.project(),
            task: String::new(),
            session: "default".into(),
        })
        .unwrap();
    let file = store.home().agent_file(record.id);
    fs::write(&file, b"invalid preserved fixture").unwrap();
    for request in [
        json!({"operation":"list"}),
        json!({"operation":"rename_session","session":"default","name":"renamed"}),
        json!({"operation":"log_retention","maxFileBytes":0}),
    ] {
        assert_eq!(f.request(request)["ok"], false);
        assert_eq!(fs::read(&file).unwrap(), b"invalid preserved fixture");
    }
    assert!(!f.home().join("trama-session-rename.json").exists());
    assert!(!f.home().join("trama-log-retention.json").exists());
}

#[test]
fn rename_journal_recovers_partial_writes_and_refuses_invalid_data() {
    let f = Fixture::new();
    let store = orkai::store::Store::open(orkai::paths::Home::at(f.home())).unwrap();
    let mut records = Vec::new();
    for name in ["first", "second"] {
        records.push(
            store
                .create_agent(orkai::model::NewAgent {
                    name: name.into(),
                    kind: orkai::model::AgentKind::Terminal,
                    cwd: f.project(),
                    task: String::new(),
                    session: "default".into(),
                })
                .unwrap(),
        );
    }
    let mut sessions = store.load_sessions().unwrap();
    let original = json!({"name":"default","records":records,"sessions":sessions});
    sessions[0].name = "recovered".into();
    for record in &mut records {
        record.session = "recovered".into();
    }
    let journal = f.home().join("trama-session-rename.json");
    fs::write(
        &journal,
        serde_json::to_vec(&json!({"old":original,
            "new":{"name":"recovered","records":records,"sessions":sessions}}))
        .unwrap(),
    )
    .unwrap();
    store.save_agent(&records[0]).unwrap(); // Crash after only one of the records was updated.
    let listing = f.ok(json!({"operation":"list"}));
    assert_eq!(listing["sessions"], json!(["recovered"]));
    assert!(
        listing["agents"]
            .as_array()
            .unwrap()
            .iter()
            .all(|a| a["session"] == "recovered")
    );
    assert!(!journal.exists());
    let before = fs::read(store.home().agent_file(records[0].id)).unwrap();
    for invalid in [
        b"not JSON".as_slice(),
        br#"{"records":[],"sessions":[]}"#.as_slice(),
    ] {
        fs::write(&journal, invalid).unwrap();
        assert_eq!(f.request(json!({"operation":"list"}))["ok"], false);
        assert_eq!(fs::read(&journal).unwrap(), invalid);
        assert_eq!(
            fs::read(store.home().agent_file(records[0].id)).unwrap(),
            before
        );
    }
}

#[test]
fn rename_journal_validates_all_snapshots_before_writing_any_record() {
    let f = Fixture::new();
    let store = orkai::store::Store::open(orkai::paths::Home::at(f.home())).unwrap();
    let records: Vec<_> = ["first", "second"]
        .into_iter()
        .map(|name| {
            store
                .create_agent(orkai::model::NewAgent {
                    name: name.into(),
                    kind: orkai::model::AgentKind::Terminal,
                    cwd: f.project(),
                    task: "preserve task".into(),
                    session: "default".into(),
                })
                .unwrap()
        })
        .collect();
    let sessions = store.load_sessions().unwrap();
    let mut next_records = records.clone();
    for record in &mut next_records {
        record.session = "renamed".into();
    }
    let mut next_sessions = sessions.clone();
    next_sessions[0].name = "renamed".into();
    let valid = json!({"old":{"name":"default","records":records,"sessions":sessions},
        "new":{"name":"renamed","records":next_records,"sessions":next_sessions}});
    let mut invalids = Vec::new();
    // Even a well-formed record with the same id/session cannot authorize other changes.
    for (field, value) in [
        ("name", json!("")),
        ("cwd", json!("relative")),
        ("bypass", json!(true)),
        ("remote_control", json!(true)),
        ("task", json!("changed")),
    ] {
        let mut bad = valid.clone();
        bad["new"]["records"][1][field] = value;
        invalids.push(bad);
    }
    // Matching forged old/new metadata must still be checked against the current record.
    let mut forged = valid.clone();
    for state in ["old", "new"] {
        forged[state]["records"][1]["task"] = json!("forged");
    }
    invalids.push(forged);
    let mut omitted = valid.clone();
    for state in ["old", "new"] {
        omitted[state]["records"].as_array_mut().unwrap().pop();
    }
    invalids.push(omitted);
    let mut duplicate = valid.clone();
    for state in ["old", "new"] {
        duplicate[state]["records"][1] = duplicate[state]["records"][0].clone();
    }
    invalids.push(duplicate);
    let mut sessions_changed = valid.clone();
    sessions_changed["new"]["sessions"][0]["created_at_ms"] = json!(0);
    invalids.push(sessions_changed);
    let mut mismatched_id = valid.clone();
    mismatched_id["new"]["records"][1]["id"] = json!(99);
    invalids.push(mismatched_id);
    let journal = f.home().join("trama-session-rename.json");
    let before_records: Vec<_> = records
        .iter()
        .map(|r| fs::read(store.home().agent_file(r.id)).unwrap())
        .collect();
    let before_sessions = fs::read(store.home().sessions_file()).unwrap();
    for invalid in invalids {
        let bytes = serde_json::to_vec(&invalid).unwrap();
        fs::write(&journal, &bytes).unwrap();
        assert_eq!(
            f.request(json!({"operation":"list"}))["ok"],
            false,
            "{invalid}"
        );
        assert_eq!(fs::read(&journal).unwrap(), bytes);
        assert_eq!(
            fs::read(store.home().sessions_file()).unwrap(),
            before_sessions
        );
        for (record, before) in records.iter().zip(&before_records) {
            assert_eq!(
                &fs::read(store.home().agent_file(record.id)).unwrap(),
                before
            );
        }
    }
    // A partial transaction is valid with either session snapshot, including after sessions
    // were published but a crash prevented removal of the journal.
    fs::write(&journal, serde_json::to_vec(&valid).unwrap()).unwrap();
    store.save_agent(&next_records[0]).unwrap();
    store.save_sessions(&next_sessions).unwrap();
    f.ok(json!({"operation":"list"}));
    assert!(!journal.exists());
    for record in &next_records {
        assert_eq!(store.load_agent(record.id).unwrap(), *record);
    }
}

#[test]
fn mutation_lock_prevents_session_writes_from_another_request() {
    use std::os::fd::AsRawFd;
    let f = Fixture::new();
    f.ok(json!({"operation":"list"}));
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(f.home().join("trama-mutation.lock"))
        .unwrap();
    assert_eq!(
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
        0
    );
    let reply =
        f.request(json!({"operation":"rename_session","session":"default","name":"blocked"}));
    assert_eq!(reply["ok"], false);
    assert!(
        reply["error"]
            .as_str()
            .unwrap()
            .contains("Another operation")
    );
    unsafe {
        libc::flock(lock.as_raw_fd(), libc::LOCK_UN);
    }
    assert_eq!(
        f.ok(json!({"operation":"list"}))["sessions"],
        json!(["default"])
    );
}

#[test]
fn archive_is_idempotent_and_preserves_staged_untracked_ignored_and_branch() {
    let mut f = Fixture::new();
    let project = f.project();
    git(&project, &["init", "-b", "main"]);
    git(&project, &["config", "user.name", "Trama Test"]);
    git(
        &project,
        &["config", "user.email", "trama-test@example.invalid"],
    );
    fs::write(project.join("tracked"), "original\n").unwrap();
    fs::write(project.join(".gitignore"), "ignored\n").unwrap();
    git(&project, &["add", "."]);
    git(&project, &["commit", "-m", "initial"]);
    let id = f.start(true);
    let listing = f.ok(json!({"operation":"list"}));
    let path = PathBuf::from(listing["agents"][0]["cwd"].as_str().unwrap());
    fs::write(path.join("tracked"), "staged\n").unwrap();
    git(&path, &["add", "tracked"]);
    fs::write(path.join("tracked"), "unstaged\n").unwrap();
    fs::write(path.join("untracked"), [0u8, 255, 1, 2]).unwrap();
    fs::write(path.join("ignored"), "preserved fixture\n").unwrap();
    assert_eq!(
        f.request(json!({"operation":"archive_worktree","agentId":id,"confirmed":true}))["ok"],
        false
    );
    f.ok(json!({"operation":"stop","agentId":id}));
    assert_eq!(
        f.request(json!({"operation":"archive_worktree","agentId":id}))["ok"],
        false
    );
    let before = Command::new("git")
        .arg("-C")
        .arg(&path)
        .args(["status", "--porcelain=v1", "--ignored"])
        .output()
        .unwrap()
        .stdout;
    let archived = f.ok(json!({"operation":"archive_worktree","agentId":id,"confirmed":true}));
    assert_eq!(archived["preservesChanges"], true);
    assert_eq!(PathBuf::from(archived["path"].as_str().unwrap()), path);
    assert_eq!(
        f.ok(json!({"operation":"archive_worktree","agentId":id,"confirmed":true})),
        archived
    );
    assert_eq!(
        fs::read_to_string(path.join("tracked")).unwrap(),
        "unstaged\n"
    );
    assert_eq!(fs::read(path.join("untracked")).unwrap(), [0u8, 255, 1, 2]);
    assert_eq!(
        fs::read_to_string(path.join("ignored")).unwrap(),
        "preserved fixture\n"
    );
    let after = Command::new("git")
        .arg("-C")
        .arg(&path)
        .args(["status", "--porcelain=v1", "--ignored"])
        .output()
        .unwrap()
        .stdout;
    assert_eq!(before, after);
    git(
        &path,
        &[
            "show-ref",
            "--verify",
            &format!("refs/heads/{}", archived["branch"].as_str().unwrap()),
        ],
    );
    let listing = f.ok(json!({"operation":"list"}));
    assert_eq!(listing["agents"][0]["archived"], true);
    for op in ["resume", "input", "merge", "remove"] {
        assert_eq!(
            f.request(json!({"operation":op,"agentId":id,"confirmed":true}))["ok"],
            false
        );
    }
}

#[test]
fn observes_local_process_parent_edges_without_promising_subagent_completeness() {
    let mut f = Fixture::new();
    let id = f.start(false);
    f.ok(json!({"operation":"input","agentId":id,"input":STANDARD.encode(b"sleep 2 & wait\r")}));
    let deadline = Instant::now() + Duration::from_secs(2);
    let tree = loop {
        let tree = f.ok(json!({"operation":"process_tree","agentId":id}));
        if tree["nodes"].as_array().unwrap().len() > 1 {
            break tree;
        }
        assert!(Instant::now() < deadline, "no child observed: {tree}");
        thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(tree["complete"], false);
    assert!(!tree["limitations"].as_array().unwrap().is_empty());
    let nodes = tree["nodes"].as_array().unwrap();
    assert!(nodes.len() <= 256);
    assert_eq!(nodes[0]["pid"], tree["rootPid"]);
    assert!(nodes[0]["parentPid"].is_null());
    for node in nodes.iter().skip(1) {
        assert!(
            nodes
                .iter()
                .any(|parent| parent["pid"] == node["parentPid"])
        );
        assert!(!node.as_object().unwrap().contains_key("args"));
        assert!(!node.as_object().unwrap().contains_key("env"));
    }
    f.ok(json!({"operation":"stop","agentId":id}));
    let stopped = f.ok(json!({"operation":"process_tree","agentId":id}));
    assert!(stopped["nodes"].as_array().unwrap().is_empty());
    assert!(stopped["rootPid"].is_null());
}

#[test]
fn log_retention_requires_reviewed_unchanged_plan_and_skips_symlinks_and_active_agents() {
    use std::os::unix::fs::symlink;
    let mut f = Fixture::new();
    let id = f.start(false);
    let directory = f.home().join(format!("agents/{id}"));
    fs::write(directory.join("holder.log"), "controlled-log\n").unwrap();
    let active = f.ok(json!({"operation":"log_retention","maxFileBytes":0}));
    assert!(active["candidates"].as_array().unwrap().is_empty());
    f.ok(json!({"operation":"stop","agentId":id}));
    // A symlink is excluded and cannot cause deletion of its target.
    let target = f.root.join("keep-data");
    fs::write(&target, "keep\n").unwrap();
    symlink(&target, directory.join("test.log")).unwrap();
    let preview = f.ok(json!({"operation":"log_retention","maxFileBytes":0}));
    assert!(preview["totalBytes"].as_u64().unwrap() > 0);
    assert!(preview["candidates"].as_array().unwrap().iter().all(|c| {
        c["path"]
            .as_str()
            .unwrap()
            .starts_with(&format!("agents/{id}/"))
    }));
    assert!(!preview.to_string().contains("controlled-log"));
    assert_eq!(
        f.request(json!({"operation":"apply_log_retention","planToken":preview["planToken"]}))["ok"],
        false
    );
    assert_eq!(
        f.request(json!({"operation":"apply_log_retention","planToken":"wrong","confirmed":true}))
            ["ok"],
        false
    );
    let original = fs::read(directory.join("output.log")).unwrap();
    let mut changed = fs::read(directory.join("holder.log")).unwrap();
    changed[0] ^= 1; // Same size, different content/ctime: size alone must never validate a plan.
    fs::write(directory.join("holder.log"), &changed).unwrap();
    assert_eq!(f.request(json!({"operation":"apply_log_retention","planToken":preview["planToken"],"confirmed":true}))["ok"], false);
    assert_eq!(
        fs::read(directory.join("output.log")).unwrap(),
        original,
        "obsolete plan removed an earlier candidate"
    );
    let swapped = f.ok(json!({"operation":"log_retention","maxFileBytes":0}));
    fs::remove_file(directory.join("holder.log")).unwrap();
    symlink(&target, directory.join("holder.log")).unwrap();
    assert_eq!(f.request(json!({"operation":"apply_log_retention","planToken":swapped["planToken"],"confirmed":true}))["ok"], false);
    assert_eq!(fs::read(directory.join("output.log")).unwrap(), original);
    let refreshed = f.ok(json!({"operation":"log_retention","maxFileBytes":0}));
    let removed = f.ok(json!({"operation":"apply_log_retention","planToken":refreshed["planToken"],"confirmed":true}));
    assert_eq!(removed["removedBytes"], refreshed["totalBytes"]);
    assert_eq!(
        removed["removedFiles"].as_u64().unwrap(),
        refreshed["candidates"].as_array().unwrap().len() as u64
    );
    assert_eq!(fs::read_to_string(&target).unwrap(), "keep\n");
    assert!(
        directory
            .join("test.log")
            .symlink_metadata()
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert!(directory.join("agent.json").is_file());
    assert!(directory.join("launch.json").is_file());
    assert_eq!(f.request(json!({"operation":"apply_log_retention","planToken":refreshed["planToken"],"confirmed":true}))["ok"], false);
    // Interrupted records are also ineligible, even when their log exceeds the threshold.
    fs::remove_file(directory.join("exit.json")).unwrap();
    let _ = fs::remove_file(directory.join("runtime.json"));
    fs::remove_file(directory.join("holder.log")).unwrap();
    fs::write(directory.join("holder.log"), "interrupted retained log\n").unwrap();
    let interrupted = f.ok(json!({"operation":"log_retention","maxFileBytes":0}));
    assert!(interrupted["candidates"].as_array().unwrap().is_empty());
    for request in [
        json!({"operation":"log_retention"}),
        json!({"operation":"log_retention","maxAgeDays":0}),
        json!({"operation":"log_retention","maxAgeDays":3651}),
        json!({"operation":"log_retention","maxFileBytes":1073741825u64}),
    ] {
        assert_eq!(f.request(request)["ok"], false);
    }
}

#[test]
fn retention_age_uses_file_modification_time_and_never_deletes_agent_metadata() {
    let f = Fixture::new();
    let store = orkai::store::Store::open(orkai::paths::Home::at(f.home())).unwrap();
    let record = store
        .create_agent(orkai::model::NewAgent {
            name: "age".into(),
            kind: orkai::model::AgentKind::Terminal,
            cwd: f.project(),
            task: String::new(),
            session: "default".into(),
        })
        .unwrap();
    let directory = store.home().agent_dir(record.id);
    fs::write(
        directory.join("exit.json"),
        serde_json::to_vec(&orkai::model::ExitInfo {
            code: Some(0),
            error: None,
            at_ms: orkai::util::now_ms(),
        })
        .unwrap(),
    )
    .unwrap();
    fs::write(directory.join("holder.log"), "old log\n").unwrap();
    fs::write(directory.join("test.log"), "recent log\n").unwrap();
    let status = Command::new("touch")
        .args(["-t", "200001010000"])
        .arg(directory.join("holder.log"))
        .status()
        .unwrap();
    assert!(status.success());
    let preview = f.ok(json!({"operation":"log_retention","maxAgeDays":30}));
    assert_eq!(
        preview["candidates"],
        json!([{"path":format!("agents/{}/holder.log",record.id),"bytes":8}])
    );
    f.ok(json!({"operation":"apply_log_retention","planToken":preview["planToken"],"confirmed":true}));
    assert!(!directory.join("holder.log").exists());
    assert_eq!(
        fs::read_to_string(directory.join("test.log")).unwrap(),
        "recent log\n"
    );
    assert!(directory.join("agent.json").is_file());
    assert!(directory.join("exit.json").is_file());
}

#[test]
fn log_export_is_a_bounded_reviewable_literal_redacted_preview() {
    let f = Fixture::new();
    let store = orkai::store::Store::open(orkai::paths::Home::at(f.home())).unwrap();
    let record = store
        .create_agent(orkai::model::NewAgent {
            name: "export".into(),
            kind: orkai::model::AgentKind::Terminal,
            cwd: f.project(),
            task: String::new(),
            session: "default".into(),
        })
        .unwrap();
    {
        let mut log = orkai::holder::oplog::OutputLog::open(
            store.home().output_log(record.id),
            orkai::protocol::TermSize::new(40, 120),
        )
        .unwrap();
        log.output(
            "fixture-secret-long and fixture-secret and segredo ç and visible text\r\n".as_bytes(),
        )
        .unwrap();
    }
    assert_eq!(
        f.request(json!({"operation":"export_logs","agentId":record.id}))["ok"],
        false
    );
    let export = f.ok(json!({"operation":"export_logs","agentId":record.id,"confirmed":true,"redactions":["fixture-secret","fixture-secret-long","segredo ç"]}));
    assert!(!export["text"].as_str().unwrap().contains("fixture-secret"));
    assert!(!export["text"].as_str().unwrap().contains("-long"));
    assert!(!export["text"].as_str().unwrap().contains("segredo ç"));
    assert!(export["text"].as_str().unwrap().contains("visible text"));
    assert_eq!(export["requiresSensitiveReview"], true);
    assert!(!export["warning"].as_str().unwrap().is_empty());
    assert_eq!(export["truncated"], false);
    for redactions in [json!([""]), json!(["x".repeat(1025)]), json!(vec!["a"; 33])] {
        assert_eq!(f.request(json!({"operation":"export_logs","agentId":record.id,"confirmed":true,"redactions":redactions}))["ok"], false);
    }
}
