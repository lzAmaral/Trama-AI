use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
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
            "trama-delivery-{}",
            orkai::util::new_uuid_v4().unwrap()
        ));
        fs::create_dir_all(root.join("project")).unwrap();
        fs::create_dir(root.join("bin")).unwrap();
        let fixture = Self { root, ids: vec![] };
        fixture.git(&["init", "-b", "main"]);
        fixture.git(&["config", "user.name", "Controlled Fixture"]);
        fixture.git(&["config", "user.email", "fixture@example.invalid"]);
        fixture.git(&[
            "remote",
            "add",
            "origin",
            "https://github.com/fixture/repository.git",
        ]);
        fs::write(fixture.project().join("file"), "original\n").unwrap();
        fixture.git(&["add", "."]);
        fixture.git(&["commit", "-m", "initial"]);
        fixture.script("codex", "exec /bin/cat");
        fixture.script("gh", "exit 91"); // No test can accidentally reach an account or network.
        fixture
    }
    fn home(&self) -> PathBuf {
        self.root.join("engine")
    }
    fn project(&self) -> PathBuf {
        self.root.join("project")
    }
    fn script(&self, name: &str, body: &str) {
        let path = self.root.join("bin").join(name);
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }
    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_trama-engine"));
        command
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
            .env("GH_HOST", "untrusted.invalid")
            .env("GH_REPO", "untrusted.invalid/other/repository")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        command
    }
    fn request(&self, value: Value) -> Value {
        let mut child = self.command().spawn().unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(&serde_json::to_vec(&value).unwrap())
            .unwrap();
        let result = child.wait_with_output().unwrap();
        assert!(result.status.success(), "engine failure");
        serde_json::from_slice(&result.stdout).unwrap()
    }
    fn ok(&self, value: Value) -> Value {
        let reply = self.request(value);
        assert_eq!(reply["ok"], true, "{reply}");
        reply["result"].clone()
    }
    fn git(&self, args: &[&str]) -> String {
        git(&self.project(), args)
    }
    fn start(&mut self, kind: &str, isolate: bool) -> u64 {
        let result = self.ok(json!({"operation":"start","kind":kind,"cwd":self.project(),"name":format!("controlled-{kind}"),"isolate":isolate}));
        let id = result["agentId"].as_u64().unwrap();
        self.ids.push(id);
        id
    }
    fn record(&self, id: u64) -> Value {
        serde_json::from_slice(
            &fs::read(self.home().join(format!("agents/{id}/agent.json"))).unwrap(),
        )
        .unwrap()
    }
    fn save(&self, id: u64, value: &Value) {
        fs::write(
            self.home().join(format!("agents/{id}/agent.json")),
            serde_json::to_vec(value).unwrap(),
        )
        .unwrap();
    }
    fn snapshot(&self, id: u64) -> Value {
        self.ok(json!({"operation":"diff_snapshot","agentId":id}))
    }
    fn review(&self, id: u64, snapshot: &Value) -> Value {
        let text = snapshot["text"].as_str().unwrap();
        let line = text.split('\n').position(|s| s == "+modified").unwrap() + 1;
        json!({"operation":"review_preview","agentId":id,"createdAtMs":snapshot["createdAtMs"],"expectedVersion":snapshot["version"],"notes":[{"line":line,"body":"Please reconsider this change.\nKeep the original behavior."}]})
    }
    fn gh_response(&self, head: &str) -> Value {
        json!({"number":7,"url":"https://github.com/fixture/repository/pull/7","title":"Controlled PR","state":"OPEN","headRefName":"main","headRefOid":head,"isCrossRepository":false,
            "statusCheckRollup":[{"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"},{"context":"external","state":"PENDING"}]})
    }
    fn set_gh(&self, value: Value) {
        fs::write(
            self.root.join("response.json"),
            serde_json::to_vec(&value).unwrap(),
        )
        .unwrap();
        self.script("gh", &format!("printf '%s\\n' \"$@\" > '{}'\n[ \"$GH_HOST\" = github.com ] || exit 81\n[ -z \"$GH_REPO\" ] || exit 82\n[ \"$GH_TELEMETRY\" = 0 ] || exit 83\n/bin/cat '{}'", self.root.join("arguments").display(), self.root.join("response.json").display()));
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
fn git(path: &Path, args: &[&str]) -> String {
    let output = Command::new("/usr/bin/git")
        .arg("-C")
        .arg(path)
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git fixture failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim_end().into()
}

#[test]
fn snapshot_identity_head_base_bytes_and_grouping_have_precise_versions() {
    let mut f = Fixture::new();
    let id = f.start("terminal", true);
    let original = f.snapshot(id);
    assert_eq!(original["version"].as_str().unwrap().len(), 64);
    let mut record = f.record(id);
    assert_eq!(original["createdAtMs"], record["created_at_ms"]);
    assert_eq!(
        f.ok(json!({"operation":"details","agentId":id}))["agent"]["createdAtMs"],
        original["createdAtMs"]
    );
    record["name"] = json!("renamed");
    record["session"] = json!("other");
    record["task"] = json!("different label");
    record["launches"] = json!(10);
    f.save(id, &record);
    assert_eq!(f.snapshot(id)["version"], original["version"]);
    let worktree = PathBuf::from(record["cwd"].as_str().unwrap());
    fs::write(worktree.join("file"), "modified\n").unwrap();
    let changed = f.snapshot(id);
    assert_ne!(changed["version"], original["version"]);
    assert!(!changed["text"].as_str().unwrap().contains('\x1b'));
    git(&worktree, &["add", "."]);
    git(&worktree, &["commit", "-m", "change"]);
    let committed = f.snapshot(id);
    assert_eq!(committed["text"], changed["text"]);
    assert_ne!(committed["version"], changed["version"]);
    record["worktree"]["base"] = committed["headOid"].clone();
    f.save(id, &record);
    let rebased = f.snapshot(id);
    assert_eq!(rebased["text"], "");
    assert_ne!(rebased["version"], committed["version"]);
    record["created_at_ms"] = json!(record["created_at_ms"].as_u64().unwrap() + 1);
    f.save(id, &record);
    assert_ne!(f.snapshot(id)["version"], rebased["version"]);
}

#[test]
fn preview_is_exact_and_shell_stale_identity_token_anchor_and_limits_are_rejected() {
    let mut f = Fixture::new();
    let id = f.start("terminal", false);
    fs::write(f.project().join("file"), "modified\n").unwrap();
    let snapshot = f.snapshot(id);
    let request = f.review(id, &snapshot);
    let preview = f.ok(request.clone());
    assert!(
        preview["text"]
            .as_str()
            .unwrap()
            .contains("Please reconsider")
    );
    assert_eq!(
        f.ok(request.clone()),
        preview,
        "preview should be deterministic"
    );
    let mut send = request.clone();
    send["operation"] = json!("send_review");
    send["reviewToken"] = preview["token"].clone();
    send["confirmed"] = json!(true);
    assert!(
        f.request(send)["error"]
            .as_str()
            .unwrap()
            .contains("never a shell")
    );
    for (field, value) in [
        ("createdAtMs", json!(0)),
        ("expectedVersion", json!("stale")),
        ("notes", json!([])),
        ("notes", json!([{"line":1,"body":"header"}])),
        ("notes", json!([{"line":999999,"body":"outside"}])),
        ("notes", json!(vec![json!({"line":7,"body":"many"}); 33])),
    ] {
        let mut bad = request.clone();
        bad[field] = value;
        assert_eq!(f.request(bad)["ok"], false);
    }
    for body in ["\u{1b}[201~\r", "\u{3}", " ", &"x".repeat(24000)] {
        let mut bad = request.clone();
        bad["notes"][0]["body"] = json!(body);
        assert_eq!(f.request(bad)["ok"], false);
    }
    fs::write(f.project().join("file"), "new edit\n").unwrap();
    assert_eq!(f.request(request)["ok"], false);
}

#[test]
fn controlled_ai_gets_only_the_confirmed_preview_once_and_archives_are_blocked() {
    let mut f = Fixture::new();
    // Capture raw PTY input in a private file; no model or provider account is involved.
    let capture = f.root.join("received");
    f.script(
        "codex",
        &format!(
            "/bin/stty raw -echo\nexec /bin/cat > '{}'",
            capture.display()
        ),
    );
    let id = f.start("codex", false);
    let ready = Instant::now() + Duration::from_secs(3);
    while !capture.exists() {
        assert!(Instant::now() < ready);
        thread::sleep(Duration::from_millis(10));
    }
    fs::write(f.project().join("file"), "modified\n").unwrap();
    let snapshot = f.snapshot(id);
    let mut request = f.review(id, &snapshot);
    let preview = f.ok(request.clone());
    request["operation"] = json!("send_review");
    request["reviewToken"] = preview["token"].clone();
    assert_eq!(f.request(request.clone())["ok"], false);
    request["confirmed"] = json!(true);
    let mut wrong = request.clone();
    wrong["reviewToken"] = json!("0".repeat(64));
    assert_eq!(f.request(wrong)["ok"], false);
    let mut altered = request.clone();
    altered["notes"][0]["body"] = json!("changed since preview");
    assert_eq!(f.request(altered)["ok"], false);
    let mut reused = request.clone();
    reused["createdAtMs"] = json!(0);
    assert_eq!(f.request(reused)["ok"], false);
    fs::write(f.project().join("file"), "changed since snapshot\n").unwrap();
    assert!(
        f.request(request.clone())["error"]
            .as_str()
            .unwrap()
            .contains("obsolete")
    );
    fs::write(f.project().join("file"), "modified\n").unwrap();
    let ack = f.ok(request.clone());
    assert_eq!(ack["deliveredToPTY"], true);
    let until = Instant::now() + Duration::from_secs(3);
    let expected = format!("\x1b[200~{}\x1b[201~\r", preview["text"].as_str().unwrap());
    loop {
        if fs::read(&capture).unwrap_or_default() == expected.as_bytes() {
            break;
        }
        assert!(
            Instant::now() < until,
            "batch was not delivered exactly: {:?}, expected {:?}",
            fs::read(&capture).unwrap_or_default(),
            expected.as_bytes()
        );
        thread::sleep(Duration::from_millis(20));
    }
    fs::write(
        f.home()
            .join(format!("agents/{id}/trama-worktree-archive.json")),
        "{}",
    )
    .unwrap();
    assert_eq!(f.request(request)["ok"], false);
    assert_eq!(fs::read(capture).unwrap(), expected.as_bytes());
}

#[test]
fn github_query_is_manual_destination_bound_and_marks_old_head_and_uncommitted_changes() {
    let mut f = Fixture::new();
    let id = f.start("terminal", false);
    let head = f.git(&["rev-parse", "HEAD"]);
    f.set_gh(f.gh_response(&head));
    let request = json!({"operation":"github_pr","agentId":id,"createdAtMs":f.record(id)["created_at_ms"],"confirmed":true});
    let mut unconfirmed = request.clone();
    unconfirmed["confirmed"] = json!(false);
    assert_eq!(f.request(unconfirmed)["ok"], false);
    assert!(!f.root.join("arguments").exists());
    let result = f.ok(request.clone());
    assert_eq!(result["matchesLocalHead"], true);
    assert_eq!(result["localDiffEmpty"], true);
    assert_eq!(result["diffVersion"], f.snapshot(id)["version"]);
    let args = fs::read_to_string(f.root.join("arguments")).unwrap();
    assert!(args.starts_with("pr\nview\nmain\n--repo\ngithub.com/fixture/repository\n--json\n"));
    assert_eq!(result["checks"][1]["state"], "PENDING");
    fs::write(f.project().join("file"), "modified\n").unwrap();
    assert_eq!(f.ok(request.clone())["localDiffEmpty"], false);
    f.set_gh(f.gh_response(&"a".repeat(40)));
    assert_eq!(f.ok(request.clone())["matchesLocalHead"], false);
    for (field, value) in [
        (
            "url",
            json!("https://evil.invalid/fixture/repository/pull/7"),
        ),
        ("headRefName", json!("other")),
        ("isCrossRepository", json!(true)),
        ("headRefOid", json!("bad")),
    ] {
        let mut response = f.gh_response(&head);
        response[field] = value;
        f.set_gh(response);
        assert_eq!(f.request(request.clone())["ok"], false);
    }
    for (field, bad) in [
        ("title", json!("bad\u{1b}[31m")),
        ("title", json!("x".repeat(1025))),
        (
            "statusCheckRollup",
            json!([{"name":"bad\u{7}","status":"COMPLETED","conclusion":"SUCCESS"}]),
        ),
    ] {
        let mut response = f.gh_response(&head);
        response[field] = bad;
        f.set_gh(response);
        assert_eq!(f.request(request.clone())["ok"], false);
    }
    for remote in [
        "http://github.com/fixture/repository",
        "https://github.com.evil.invalid/fixture/repository",
        "https://name@github.com/fixture/repository",
        "https://github.com/fixture/repository/extra",
        "ssh://git@github.com:2222/fixture/repository",
        "git@evil.invalid:fixture/repository",
        "https://github.com/../repository",
        "https://github.com/fixture/repository?redirect=evil",
    ] {
        f.git(&["remote", "set-url", "origin", remote]);
        fs::remove_file(f.root.join("arguments")).ok();
        assert_eq!(f.request(request.clone())["ok"], false, "{remote}");
        assert!(
            !f.root.join("arguments").exists(),
            "invalid destination launched gh"
        );
    }
    for remote in [
        "git@github.com:fixture/repository.git",
        "ssh://git@github.com/fixture/repository.git",
    ] {
        f.git(&["remote", "set-url", "origin", remote]);
        f.set_gh(f.gh_response(&head));
        assert_eq!(f.ok(request.clone())["repository"], "fixture/repository");
    }
}

#[test]
fn github_timeout_output_error_and_number_limits_are_safe() {
    let mut f = Fixture::new();
    let id = f.start("terminal", false);
    let request = json!({"operation":"github_pr","agentId":id,"createdAtMs":f.record(id)["created_at_ms"],"confirmed":true,"number":7});
    let mut invalid = request.clone();
    invalid["number"] = json!(0);
    assert_eq!(f.request(invalid)["ok"], false);
    f.script("gh", "printf 'PRIVATE_STDERR' >&2\nexit 1");
    assert!(
        !f.request(request.clone())
            .to_string()
            .contains("PRIVATE_STDERR")
    );
    f.script("gh", "exec /usr/bin/yes oversized");
    assert!(
        f.request(request.clone())["error"]
            .as_str()
            .unwrap()
            .contains("size limit")
    );
    f.script("gh", "exec /bin/sleep 30");
    let start = Instant::now();
    let response = f.request(request.clone());
    assert!(response["error"].as_str().unwrap().contains("timed out"));
    assert!(start.elapsed() < Duration::from_secs(12));
    let mut response = f.gh_response(&f.git(&["rev-parse", "HEAD"]));
    response["number"] = json!(8);
    f.set_gh(response);
    assert_eq!(f.request(request)["ok"], false);
}

#[test]
fn bounded_diff_refuses_truncation_and_external_diff_commands() {
    let mut f = Fixture::new();
    let id = f.start("terminal", false);
    fs::write(f.project().join("file"), "x".repeat(520000)).unwrap();
    assert_eq!(
        f.request(json!({"operation":"diff_snapshot","agentId":id}))["ok"],
        false
    );
    fs::write(f.project().join("file"), "modified\n").unwrap();
    let marker = f.root.join("must-not-run");
    f.git(&[
        "config",
        "diff.external",
        &format!("touch {}", marker.display()),
    ]);
    assert!(
        f.snapshot(id)["text"]
            .as_str()
            .unwrap()
            .contains("+modified")
    );
    assert!(!marker.exists());
}

#[test]
fn send_review_rejects_working_paused_lost_and_different_nested_provider() {
    use orkai::{
        model::{AgentKind, NewAgent, RuntimeInfo, StatusReport},
        protocol::{ClientMsg, HolderMsg, PROTOCOL_VERSION, Welcome},
    };
    use std::net::TcpListener;
    let f = Fixture::new();
    let store = orkai::store::Store::open(orkai::paths::Home::at(f.home())).unwrap();
    let record = store
        .create_agent(NewAgent {
            name: "fake-holder".into(),
            kind: AgentKind::Codex,
            cwd: f.project(),
            task: String::new(),
            session: "default".into(),
        })
        .unwrap();
    let id = u64::from(record.id);
    fs::write(f.project().join("file"), "modified\n").unwrap();
    let snapshot = f.snapshot(id);
    let mut request = f.review(id, &snapshot);
    let preview = f.ok(request.clone());
    request["operation"] = json!("send_review");
    request["reviewToken"] = preview["token"].clone();
    request["confirmed"] = json!(true);
    for (state, nested) in [
        ("Working", Value::Null),
        ("Paused", Value::Null),
        (
            "Idle",
            json!({"kind":"claude","pid":1,"cwd":null,"since_ms":0}),
        ),
    ] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let runtime = RuntimeInfo {
            holder_pid: std::process::id(),
            child_pid: None,
            port,
            token: "fixture".into(),
            started_at_ms: 0,
            protocol: PROTOCOL_VERSION,
            version: "fixture".into(),
            exe: None,
        };
        fs::write(
            store.home().runtime_file(record.id),
            serde_json::to_vec(&runtime).unwrap(),
        )
        .unwrap();
        let status: StatusReport = serde_json::from_value(json!({"state":state.to_lowercase(),"state_since_ms":0,"started_at_ms":0,"rows":40,"cols":120,"nested":nested})).unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            assert!(matches!(
                ClientMsg::read(&mut stream).unwrap(),
                ClientMsg::Hello(_)
            ));
            stream
                .write_all(
                    &HolderMsg::Welcome(Welcome {
                        agent_id: record.id,
                        protocol: PROTOCOL_VERSION,
                        version: "fixture".into(),
                        holder_pid: std::process::id(),
                    })
                    .to_frame(),
                )
                .unwrap();
            stream
                .write_all(&HolderMsg::Status(status).to_frame())
                .unwrap();
            assert!(
                ClientMsg::read(&mut stream).is_err(),
                "rejected state received input"
            );
        });
        assert_eq!(f.request(request.clone())["ok"], false, "{state}");
        server.join().unwrap();
    }
    fs::remove_file(store.home().runtime_file(record.id)).unwrap();
    assert_eq!(f.request(request)["ok"], false, "lost holder");
}

#[test]
fn github_timeout_kills_grandchildren_and_preserves_the_holder_and_reused_id_does_not_query() {
    let mut f = Fixture::new();
    let id = f.start("terminal", false);
    let parent = f.root.join("gh.pid");
    let descendant = f.root.join("helper.pid");
    f.script(
        "gh",
        &format!(
            "printf '%s' $$ > '{}'\n/bin/sleep 30 &\nprintf '%s' $! > '{}'\nwait",
            parent.display(),
            descendant.display()
        ),
    );
    let request = json!({"operation":"github_pr","agentId":id,"createdAtMs":f.record(id)["created_at_ms"],"confirmed":true});
    let mut stale = request.clone();
    stale["createdAtMs"] = json!(0);
    assert_eq!(f.request(stale)["ok"], false);
    assert!(!parent.exists());
    let result = f.request(request);
    assert!(result["error"].as_str().unwrap().contains("timed out"));
    let parent: i32 = fs::read_to_string(parent).unwrap().parse().unwrap();
    let child: i32 = fs::read_to_string(descendant).unwrap().parse().unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while unsafe { libc::kill(child, 0) } == 0 && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(unsafe { libc::kill(parent, 0) }, -1);
    assert_eq!(
        unsafe { libc::kill(child, 0) },
        -1,
        "grandchild survived timeout"
    );
    assert!(f.ok(json!({"operation":"list"}))["agents"][0]["state"] != "exited");
}

#[test]
fn local_reads_disable_clean_and_process_filters_including_included_configuration() {
    let mut f = Fixture::new();
    let id = f.start("terminal", false);
    let marker = f.root.join("filter-must-not-run");
    let include = f.root.join("included-filter-config");
    fs::write(&include, format!("[filter \"audit\"]\n clean = touch {}; cat\n process = touch {}; exit 1\n required = true\n", marker.display(), marker.display())).unwrap();
    f.git(&["config", "include.path", include.to_str().unwrap()]);
    fs::write(f.project().join(".gitattributes"), "file filter=audit\n").unwrap();
    fs::write(f.project().join("file"), "modified\n").unwrap();
    assert!(
        f.snapshot(id)["text"]
            .as_str()
            .unwrap()
            .contains("+modified")
    );
    assert!(!marker.exists(), "local review executed a process filter");
    // Cover clean independently rather than relying on process taking precedence.
    fs::write(
        &include,
        format!(
            "[filter \"audit\"]\n clean = touch {}; cat\n required = true\n",
            marker.display()
        ),
    )
    .unwrap();
    let head = f.snapshot(id)["headOid"].as_str().unwrap().to_owned();
    f.set_gh(f.gh_response(&head));
    let result = f.ok(json!({"operation":"github_pr","agentId":id,"createdAtMs":f.record(id)["created_at_ms"],"confirmed":true}));
    assert_eq!(result["localDiffEmpty"], false);
    assert!(
        !marker.exists(),
        "local diff/status executed a clean filter"
    );
}

#[test]
fn github_rejects_branch_or_origin_changed_during_query_even_at_the_same_commit() {
    let mut f = Fixture::new();
    let id = f.start("terminal", false);
    let head = f.git(&["rev-parse", "HEAD"]);
    f.git(&["branch", "other"]);
    let request = json!({"operation":"github_pr","agentId":id,"createdAtMs":f.record(id)["created_at_ms"],"confirmed":true});
    f.set_gh(f.gh_response(&head));
    f.script(
        "gh",
        &format!(
            "/usr/bin/git -C '{}' checkout other >/dev/null 2>&1\n/bin/cat '{}'",
            f.project().display(),
            f.root.join("response.json").display()
        ),
    );
    assert_eq!(f.request(request.clone())["ok"], false);
    f.git(&["checkout", "main"]);
    f.script("gh", &format!("/usr/bin/git -C '{}' remote set-url origin https://github.com/fixture/another.git\n/bin/cat '{}'", f.project().display(), f.root.join("response.json").display()));
    assert_eq!(f.request(request)["ok"], false);
}

#[test]
fn existing_agent_mutations_reject_reused_identity_before_any_effect() {
    let mut f = Fixture::new();
    let id = f.start("terminal", false);
    let record = f.record(id);
    for operation in [
        "input",
        "resize",
        "stop",
        "resume",
        "remove",
        "move_agent",
        "archive_worktree",
        "merge",
    ] {
        let result = f.request(json!({"operation":operation,"agentId":id,"createdAtMs":0,"confirmed":true,"message":"never commit"}));
        assert_eq!(result["ok"], false, "{operation}");
        assert!(
            result["error"]
                .as_str()
                .unwrap()
                .contains("identity changed"),
            "{operation}: {result}"
        );
        assert_eq!(f.record(id), record);
    }
    assert!(f.ok(json!({"operation":"list"}))["agents"][0]["state"] != "exited");
    assert!(
        !f.home()
            .join(format!("agents/{id}/trama-worktree-archive.json"))
            .exists()
    );
}

#[test]
fn slow_manual_github_query_does_not_block_terminal_input_or_resize() {
    let mut f = Fixture::new();
    let id = f.start("terminal", false);
    let head = f.git(&["rev-parse", "HEAD"]);
    let born = f.record(id)["created_at_ms"].clone();
    f.set_gh(f.gh_response(&head));
    let active = f.root.join("query-active");
    let release = f.root.join("query-release");
    f.script("gh", &format!(
        "/usr/bin/touch '{}'\nwhile [ ! -f '{}' ]; do /bin/sleep 0.05; done\n/bin/cat '{}'",
        active.display(), release.display(), f.root.join("response.json").display()
    ));
    let mut query = f.command().spawn().unwrap();
    query.stdin.take().unwrap().write_all(&serde_json::to_vec(&json!({
        "operation":"github_pr","agentId":id,"createdAtMs":born,"confirmed":true
    })).unwrap()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while !active.exists() {
        assert!(Instant::now() < deadline, "controlled query never started");
        thread::sleep(Duration::from_millis(10));
    }
    let input = f.request(json!({"operation":"input","agentId":id,"createdAtMs":born,"input":"DQo="}));
    let resize = f.request(json!({"operation":"resize","agentId":id,"createdAtMs":born,"rows":24,"cols":80}));
    let still_querying = query.try_wait().unwrap().is_none();
    fs::write(&release, "release").unwrap();
    let output = query.wait_with_output().unwrap();
    assert_eq!(input["ok"], true, "{input}");
    assert_eq!(resize["ok"], true, "{resize}");
    assert!(still_querying, "input must finish before the query is released");
    let response: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(response["ok"], true, "{response}");
}
