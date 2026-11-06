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
