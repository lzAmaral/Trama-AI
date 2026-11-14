use orkai::{
    model::{AgentKind, NewAgent, RuntimeInfo, StatusReport},
    paths::Home,
    protocol::{ClientMsg, HolderMsg, PROTOCOL_VERSION, Welcome},
    store::Store,
};
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    net::TcpListener,
    os::{fd::AsRawFd, unix::fs::PermissionsExt},
    path::PathBuf,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

struct Fixture {
    root: PathBuf,
    ids: Vec<u32>,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "trama-prompt-{}",
            orkai::util::new_uuid_v4().unwrap()
        ));
        fs::create_dir_all(root.join("project")).unwrap();
        fs::create_dir(root.join("bin")).unwrap();
        Self { root, ids: vec![] }
    }
    fn home(&self) -> PathBuf {
        self.root.join("engine")
    }
    fn store(&self) -> Store {
        Store::open(Home::at(self.home())).unwrap()
    }
    fn request(&self, value: Value) -> Value {
        let mut child = Command::new(env!("CARGO_BIN_EXE_trama-engine"))
            .args(["--request", "--home"])
            .arg(self.home())
            .env(
                "PATH",
                format!(
                    "{}:/usr/bin:/bin:/usr/sbin:/sbin",
                    self.root.join("bin").display()
                ),
            )
            .env("SHELL", "/bin/sh")
            .env_remove("ENV")
            .env_remove("BASH_ENV")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(&serde_json::to_vec(&value).unwrap())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        serde_json::from_slice(&output.stdout).unwrap()
    }
    fn ok(&self, value: Value) -> Value {
        let reply = self.request(value);
        assert_eq!(reply["ok"], true, "{reply}");
        reply["result"].clone()
    }
    fn record(&self, id: u32) -> Value {
        serde_json::to_value(self.store().load_agent(id).unwrap()).unwrap()
    }
    fn prompt(&self, id: u32, text: &str) -> Value {
        json!({"operation":"send_prompt","agentId":id,"createdAtMs":self.record(id)["created_at_ms"],"message":text,"confirmed":true})
    }
    fn controlled_ai(&mut self) -> u32 {
        let path = self.root.join("bin/codex");
        fs::write(
            &path,
            format!(
                "#!/bin/sh\n/bin/stty raw -echo\nexec /bin/cat > '{}'\n",
                self.root.join("received").display()
            ),
        )
        .unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        let result = self.ok(json!({"operation":"start","kind":"codex","cwd":self.root.join("project"),"name":"controlled","task":""}));
        let id = result["agentId"].as_u64().unwrap() as u32;
        self.ids.push(id);
        assert_eq!(result["createdAtMs"], self.record(id)["created_at_ms"]);
        let deadline = Instant::now() + Duration::from_secs(4);
        while !self.root.join("received").exists() {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(10));
        }
        id
    }
    fn fake_record(&self, kind: AgentKind) -> u32 {
        self.store()
            .create_agent(NewAgent {
                name: "fake".into(),
                kind,
                cwd: self.root.join("project"),
                task: String::new(),
                session: "default".into(),
            })
            .unwrap()
            .id
    }
    fn received(&self, expected: &[u8]) {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let bytes = fs::read(self.root.join("received")).unwrap();
            if bytes == expected {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "unexpected input length {}, wanted {}",
                bytes.len(),
                expected.len()
            );
            thread::sleep(Duration::from_millis(10));
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        for id in &self.ids {
            let runtime = self.store().read_runtime(*id).ok().flatten();
            let _ = self.request(json!({"operation":"stop","agentId":id}));
            let deadline = Instant::now() + Duration::from_secs(3);
            while self.store().read_runtime(*id).ok().flatten().is_some()
                || runtime
                    .as_ref()
                    .is_some_and(|r| unsafe { libc::kill(r.holder_pid as i32, 0) } == 0)
            {
                if Instant::now() >= deadline {
                    if !thread::panicking() {
                        panic!("controlled holder survived cleanup");
                    }
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn controlled_cat_receives_exact_utf8_multiline_once_and_shell_text_stays_literal() {
    let mut f = Fixture::new();
    let id = f.controlled_ai();
    let marker = f.root.join("must-not-execute");
    let text = format!(
        "Olá 👨‍👩‍👧‍👦 می‌روم\n\t$(touch {}) ; `touch {}`\nsecond line",
        marker.display(),
        marker.display()
    );
    // A slow list/GitHub metadata lock must not block prompt transport.
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(f.home().join("trama-mutation.lock"))
        .unwrap();
    assert_eq!(
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
        0
    );
    let ack = f.ok(f.prompt(id, &text));
    assert_eq!(
        ack,
        json!({"agentId":id,"createdAtMs":f.record(id)["created_at_ms"],"deliveredToPTY":true})
    );
    drop(lock);
    let expected = format!("\x1b[200~{text}\x1b[201~\r");
    f.received(expected.as_bytes());
    thread::sleep(Duration::from_millis(100));
    assert_eq!(
        fs::read(f.root.join("received")).unwrap(),
        expected.as_bytes()
    );
    assert!(!marker.exists());
    let runtime = f.store().read_runtime(id).unwrap().unwrap();
    assert_eq!(unsafe { libc::kill(runtime.holder_pid as i32, 0) }, 0);
    assert!(
        orkai::client::peek(&runtime).is_ok(),
        "request exit killed holder"
    );
    f.ok(json!({"operation":"stop","agentId":id}));
    let deadline = Instant::now() + Duration::from_secs(3);
    while f.store().read_runtime(id).unwrap().is_some() {
        assert!(
            Instant::now() < deadline,
            "holder did not clean up after stop"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn confirmation_identity_controls_archive_and_exact_utf8_byte_bounds_fail_without_input() {
    let mut f = Fixture::new();
    let id = f.controlled_ai();
    let request = f.prompt(id, "valid");
    for (field, value) in [
        ("confirmed", json!(false)),
        ("confirmed", Value::Null),
        ("createdAtMs", json!(0)),
        ("createdAtMs", Value::Null),
        ("message", Value::Null),
        ("message", json!(" \n\t")),
        ("message", json!("x".repeat(23_988))),
        ("message", json!("ç".repeat(11_994))),
    ] {
        let mut bad = request.clone();
        bad[field] = value;
        assert_eq!(f.request(bad)["ok"], false, "{field}");
    }
    for c in (0..=0x9f)
        .filter_map(char::from_u32)
        .filter(|c| c.is_control() && *c != '\n' && *c != '\t')
    {
        let mut bad = request.clone();
        bad["message"] = json!(format!("a{c}b"));
        assert_eq!(f.request(bad)["ok"], false, "control {c:?}");
    }
    assert_eq!(fs::read(f.root.join("received")).unwrap(), b"");
    let archive = f
        .home()
        .join(format!("agents/{id}/trama-worktree-archive.json"));
    fs::write(&archive, "{}").unwrap();
    assert_eq!(f.request(request)["ok"], false);
    fs::remove_file(archive).unwrap();
    let boundary = "ç".repeat(11_993) + "x";
    assert_eq!(boundary.len() + 13, 24_000);
    f.ok(f.prompt(id, &boundary));
    f.received(format!("\x1b[200~{boundary}\x1b[201~\r").as_bytes());
}

// One authenticated socket serves status and input; no real provider is ever launched here.
fn fake_status_case(state: &str, nested: Value, exit: Value, mutation: &str, accept: bool) {
    let f = Fixture::new();
    let id = f.fake_record(AgentKind::Codex);
    let request = f.prompt(id, "exact\ntext");
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let runtime = RuntimeInfo {
        holder_pid: std::process::id(),
        child_pid: None,
        port: listener.local_addr().unwrap().port(),
        token: "controlled-token".into(),
        started_at_ms: 0,
        protocol: PROTOCOL_VERSION,
        version: "fixture".into(),
        exe: None,
    };
    fs::write(
        f.store().home().runtime_file(id),
        serde_json::to_vec(&runtime).unwrap(),
    )
    .unwrap();
    let status: StatusReport = serde_json::from_value(json!({"state":state,"state_since_ms":0,"started_at_ms":0,"rows":40,"cols":120,"nested":nested,"exit":exit})).unwrap();
    let home = f.home();
    let mutation = mutation.to_string();
    let server = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(4);
        let (mut stream, _) = loop {
            if let Ok(pair) = listener.accept() {
                break pair;
            }
            assert!(Instant::now() < deadline, "engine never connected");
            thread::sleep(Duration::from_millis(5));
        };
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let ClientMsg::Hello(hello) = ClientMsg::read(&mut stream).unwrap() else {
            panic!("not authenticated");
        };
        assert_eq!(hello.token, runtime.token);
        stream
            .write_all(
                &HolderMsg::Welcome(Welcome {
                    agent_id: if mutation == "welcome" { id + 1 } else { id },
                    protocol: PROTOCOL_VERSION,
                    version: "fixture".into(),
                    holder_pid: std::process::id(),
                })
                .to_frame(),
            )
            .unwrap();
        let store = Store::open(Home::at(home)).unwrap();
        match mutation.as_str() {
            "record" => {
                let mut record = store.load_agent(id).unwrap();
                record.created_at_ms += 1;
                fs::write(
                    store.home().agent_file(id),
                    serde_json::to_vec(&record).unwrap(),
                )
                .unwrap();
            }
            "archive" => {
                fs::write(
                    store
                        .home()
                        .agent_dir(id)
                        .join("trama-worktree-archive.json"),
                    "{}",
                )
                .unwrap();
            }
            "exit" => {
                fs::write(store.home().exit_file(id), br#"{"code":0,"at_ms":0}"#).unwrap();
            }
            "runtime" => {
                let mut changed = runtime.clone();
                changed.token = "replacement".into();
                fs::write(
                    store.home().runtime_file(id),
                    serde_json::to_vec(&changed).unwrap(),
                )
                .unwrap();
            }
            _ => {}
        }
        // A mismatched welcome can close before status is written.
        if mutation != "welcome" && mutation != "no-status" {
            stream
                .write_all(&HolderMsg::Status(status).to_frame())
                .unwrap();
        }
        if accept {
            assert_eq!(
                ClientMsg::read(&mut stream).unwrap(),
                ClientMsg::Input(b"\x1b[200~exact\ntext\x1b[201~\r".to_vec())
            );
        }
        assert!(
            ClientMsg::read(&mut stream).is_err(),
            "unexpected or repeated input"
        );
        assert!(
            listener.accept().is_err(),
            "delivery opened a second socket"
        );
    });
    assert_eq!(f.request(request)["ok"], accept, "state {state}");
    server.join().unwrap();
}

#[test]
fn statuses_and_provider_mismatch_are_rejected_on_the_delivery_connection() {
    for state in ["working", "paused", "lost", "exited"] {
        fake_status_case(state, Value::Null, Value::Null, "", false);
    }
    fake_status_case(
        "idle",
        json!({"kind":"claude","pid":1,"cwd":null,"since_ms":0}),
        Value::Null,
        "",
        false,
    );
    fake_status_case("idle", Value::Null, json!({"code":0,"at_ms":0}), "", false);
    for mutation in [
        "record",
        "runtime",
        "archive",
        "exit",
        "welcome",
        "no-status",
    ] {
        fake_status_case("idle", Value::Null, Value::Null, mutation, false);
    }
    fake_status_case("idle", Value::Null, Value::Null, "", true);
    fake_status_case("done", Value::Null, Value::Null, "", true);
}

#[test]
fn shell_lost_and_persisted_exit_do_not_start_a_provider() {
    let f = Fixture::new();
    let shell = f.fake_record(AgentKind::Terminal);
    assert_eq!(
        f.request(f.prompt(shell, "touch must-not-run"))["ok"],
        false
    );
    let ai = f.fake_record(AgentKind::Codex);
    assert_eq!(f.request(f.prompt(ai, "hello"))["ok"], false);
    fs::write(f.store().home().exit_file(ai), br#"{"code":0,"at_ms":0}"#).unwrap();
    assert_eq!(f.request(f.prompt(ai, "hello"))["ok"], false);
    assert!(f.store().read_runtime(ai).unwrap().is_none());
}

fn status_frame(state: &str, nested: Value) -> Vec<u8> {
    let status: StatusReport = serde_json::from_value(json!({"state":state,"state_since_ms":0,"started_at_ms":0,"rows":40,"cols":120,"nested":nested})).unwrap();
    HolderMsg::Status(status).to_frame()
}

/// Prefix bytes are queued together with Welcome/idle. Optional fragments keep a partial
/// frame alive; the server verifies no rejected request ever writes an Input frame.
fn queued_frames_case(
    prefix: Vec<u8>,
    fragments: Vec<Vec<u8>>,
    delay: Duration,
    accept: bool,
) -> Value {
    let f = Fixture::new();
    let id = f.fake_record(AgentKind::Codex);
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let runtime = RuntimeInfo {
        holder_pid: std::process::id(),
        child_pid: None,
        port: listener.local_addr().unwrap().port(),
        token: "queued-fixture".into(),
        started_at_ms: 0,
        protocol: PROTOCOL_VERSION,
        version: "fixture".into(),
        exe: None,
    };
    fs::write(
        f.store().home().runtime_file(id),
        serde_json::to_vec(&runtime).unwrap(),
    )
    .unwrap();
    let server = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(4);
        let (mut stream, _) = loop {
            if let Ok(pair) = listener.accept() {
                break pair;
            }
            assert!(Instant::now() < deadline, "no authenticated connection");
            thread::sleep(Duration::from_millis(5));
        };
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        stream
            .set_write_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let ClientMsg::Hello(hello) = ClientMsg::read(&mut stream).unwrap() else {
            panic!("no Hello");
        };
        assert_eq!(hello.token, runtime.token);
        let mut queued = HolderMsg::Welcome(Welcome {
            agent_id: id,
            protocol: PROTOCOL_VERSION,
            version: "fixture".into(),
            holder_pid: runtime.holder_pid,
        })
        .to_frame();
        queued.extend(status_frame("idle", Value::Null));
        queued.extend(prefix);
        // In particular, idle and the unsafe delta are in the same TCP write.
        let _ = stream.write_all(&queued);
        for fragment in fragments {
            thread::sleep(delay);
            if stream.write_all(&fragment).is_err() {
                break;
            }
        }
        if accept {
            assert_eq!(
                ClientMsg::read(&mut stream).unwrap(),
                ClientMsg::Input(b"\x1b[200~queued text\x1b[201~\r".to_vec())
            );
        }
        assert!(
            ClientMsg::read(&mut stream).is_err(),
            "rejected/repeated input was delivered"
        );
        assert!(
            listener.accept().is_err(),
            "second holder connection opened"
        );
    });
    let started = Instant::now();
    let reply = f.request(f.prompt(id, "queued text"));
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "status stream escaped deadline"
    );
    assert_eq!(reply["ok"], accept, "{reply}");
    server.join().unwrap();
    reply
}

#[test]
fn queued_state_deltas_override_idle_on_the_same_authenticated_socket() {
    for state in ["paused", "working", "lost", "exited"] {
        queued_frames_case(
            status_frame(state, Value::Null),
            vec![],
            Duration::ZERO,
            false,
        );
    }
    queued_frames_case(
        status_frame("idle", json!({"kind":"claude","pid":1,"since_ms":0})),
        vec![],
        Duration::ZERO,
        false,
    );
    let exit = HolderMsg::Exited(orkai::model::ExitInfo {
        code: Some(0),
        error: None,
        at_ms: 0,
    })
    .to_frame();
    queued_frames_case(exit, vec![], Duration::ZERO, false);
    let mut output_then_paused = HolderMsg::Output(b"unattached output".to_vec()).to_frame();
    output_then_paused.extend(status_frame("paused", Value::Null));
    queued_frames_case(output_then_paused, vec![], Duration::ZERO, false);
    let mut paused_then_done = status_frame("paused", Value::Null);
    paused_then_done.extend(status_frame("done", Value::Null));
    queued_frames_case(paused_then_done, vec![], Duration::ZERO, true);
}

#[test]
fn fragmented_state_frames_must_complete_before_input() {
    let paused = status_frame("paused", Value::Null);
    // Split the length header, then split inside the JSON payload.
    queued_frames_case(
        paused[..2].to_vec(),
        vec![paused[2..15].to_vec(), paused[15..].to_vec()],
        Duration::from_millis(20),
        false,
    );
    let done = status_frame("done", Value::Null);
    queued_frames_case(
        done[..7].to_vec(),
        vec![done[7..].to_vec()],
        Duration::from_millis(20),
        true,
    );
}

#[test]
fn status_flood_oversized_frames_and_slow_partial_frames_are_bounded() {
    let frame = HolderMsg::Output(vec![b'x'; 4096]).to_frame();
    let flood: Vec<u8> = frame.iter().copied().cycle().take(300 * 1024).collect();
    let result = queued_frames_case(flood, vec![], Duration::ZERO, false);
    assert!(result["error"].as_str().unwrap().contains("size limit"));
    queued_frames_case(
        (65_537u32).to_le_bytes().to_vec(),
        vec![],
        Duration::ZERO,
        false,
    );
    let paused = status_frame("paused", Value::Null);
    let fragments = paused[5..].iter().map(|b| vec![*b]).collect();
    let result = queued_frames_case(
        paused[..5].to_vec(),
        fragments,
        Duration::from_millis(25),
        false,
    );
    assert!(result["error"].as_str().unwrap().contains("timed out"));
}
