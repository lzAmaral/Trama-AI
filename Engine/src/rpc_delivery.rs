//! Versioned review delivery and explicitly requested GitHub reads. No provider integration lives here.
use super::*;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    os::unix::process::CommandExt,
    path::Path,
    process::{Command, Stdio},
    sync::atomic::{AtomicI32, Ordering},
};

const LIMIT: usize = 512_000;
const INPUT_LIMIT: usize = 24_000;
const DEADLINE: Duration = Duration::from_secs(8);
static CHILD_GROUP: AtomicI32 = AtomicI32::new(0);

extern "C" fn cancel_request(_: libc::c_int) {
    // Async-signal-safe cleanup; no allocations, locks, or Rust destructors in the handler.
    let pid = CHILD_GROUP.load(Ordering::SeqCst);
    unsafe {
        if pid > 0 {
            libc::kill(-pid, libc::SIGKILL);
        }
        libc::_exit(128 + libc::SIGTERM);
    }
}
pub(super) fn isolate_request() -> io::Result<()> {
    unsafe {
        if libc::setpgid(0, 0) != 0 {
            return Err(io::Error::last_os_error());
        }
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = cancel_request as *const () as usize;
        libc::sigemptyset(&mut action.sa_mask);
        if libc::sigaction(libc::SIGTERM, &action, std::ptr::null_mut()) != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ReviewNote {
    line: usize,
    body: String,
}

// All subprocess output is bounded and stderr is discarded, including authentication errors.
// Each command owns a group including helpers. SIGTERM on the private sidecar group forwards
// SIGKILL to that command group; timeout and output errors clean up the same group locally.
fn run(command: &mut Command, deadline: Instant, allow_diff_exit: bool) -> io::Result<Vec<u8>> {
    use std::io::Read;
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut old_mask: libc::sigset_t = unsafe { std::mem::zeroed() };
    let mut blocked: libc::sigset_t = unsafe { std::mem::zeroed() };
    unsafe {
        libc::sigemptyset(&mut blocked);
        libc::sigaddset(&mut blocked, libc::SIGTERM);
        if libc::sigprocmask(libc::SIG_BLOCK, &blocked, &mut old_mask) != 0 {
            return Err(io::Error::last_os_error());
        }
        // Restore the child's mask before exec. SIGTERM remains blocked in the parent until
        // the new group is published, closing cancellation's spawn/register race.
        command.process_group(0).pre_exec(move || {
            if libc::sigprocmask(libc::SIG_SETMASK, &old_mask, std::ptr::null_mut()) != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let spawned = command.spawn();
    if let Ok(child) = &spawned {
        CHILD_GROUP.store(child.id() as i32, Ordering::SeqCst);
    }
    unsafe {
        libc::sigprocmask(libc::SIG_SETMASK, &old_mask, std::ptr::null_mut());
    }
    let mut child = spawned?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("missing stdout"))?;
    let fd = stdout.as_raw_fd();
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        unsafe {
            libc::kill(-(child.id() as i32), libc::SIGKILL);
        }
        CHILD_GROUP.store(0, Ordering::SeqCst);
        let _ = child.wait();
        return Err(io::Error::last_os_error());
    }
    let result = (|| {
        let mut bytes = Vec::new();
        let mut buffer = [0u8; 8192];
        loop {
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "subprocess deadline",
                ));
            }
            // Bound draining as well as storage: a constantly writing process cannot starve the deadline.
            for _ in 0..64 {
                match stdout.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(n) => {
                        if bytes.len() + n > LIMIT {
                            return Err(invalid("command output exceeds size limit"));
                        }
                        bytes.extend_from_slice(&buffer[..n]);
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e),
                }
            }
            // Observe exit without reaping: the leader's PID must remain reserved until its
            // process group has been cleaned up. This prevents PID reuse from changing ownership.
            let mut status: libc::siginfo_t = unsafe { std::mem::zeroed() };
            if unsafe {
                libc::waitid(
                    libc::P_PID,
                    child.id(),
                    &mut status,
                    libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
                )
            } != 0
            {
                return Err(io::Error::last_os_error());
            }
            if unsafe { status.si_pid() } != 0 {
                // Read only bytes already available, never wait on a pipe inherited by a descendant.
                loop {
                    match stdout.read(&mut buffer) {
                        Ok(0) => break,
                        Ok(n) => {
                            if bytes.len() + n > LIMIT {
                                return Err(invalid("command output exceeds size limit"));
                            }
                            bytes.extend_from_slice(&buffer[..n]);
                        }
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                        Err(e) => return Err(e),
                    }
                    if Instant::now() >= deadline {
                        return Err(io::Error::new(
                            io::ErrorKind::TimedOut,
                            "subprocess deadline",
                        ));
                    }
                }
                if status.si_code == libc::CLD_EXITED
                    && (unsafe { status.si_status() } == 0
                        || allow_diff_exit && unsafe { status.si_status() } == 1)
                {
                    return Ok(bytes);
                }
                return Err(io::Error::other("command failed"));
            }
            thread::sleep(Duration::from_millis(5));
        }
    })();
    // Also remove descendants after a successful command exits without closing inherited pipes.
    unsafe {
        libc::kill(-(child.id() as i32), libc::SIGKILL);
    }
    CHILD_GROUP.store(0, Ordering::SeqCst);
    let _ = child.wait();
    result
}

fn git_command(path: &Path) -> io::Result<Command> {
    let program = orkai::launch::resolve_program("git")?;
    let mut command = Command::new(program);
    // Remove repository-context overrides. No external diff/textconv/pager or credential helper is used.
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().starts_with("GIT_") {
            command.env_remove(key);
        }
    }
    command
        .args(["--no-pager", "--no-optional-locks", "-C"])
        .arg(path)
        .args([
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.hooksPath=/dev/null",
        ])
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_ATTR_NOSYSTEM", "1");
    Ok(command)
}
fn git(path: &Path, args: &[&str], deadline: Instant, diff: bool) -> io::Result<Vec<u8>> {
    // --no-textconv and --no-ext-diff do not disable clean/process filters. Discover effective
    // local driver keys using config (which does not inspect file contents), then disable every
    // driver on the command line. Never execute repository-configured code during a local read.
    let mut config = git_command(path)?;
    config.args([
        "config",
        "--null",
        "--name-only",
        "--get-regexp",
        r"^filter\..*\.(clean|process|required)$",
    ]);
    let keys = run(&mut config, deadline, true)?;
    let mut command = git_command(path)?;
    for key in keys.split(|b| *b == 0).filter(|key| !key.is_empty()) {
        let key = std::str::from_utf8(key).map_err(|_| invalid("Git filter key is not UTF-8"))?;
        if !key.starts_with("filter.") || key.chars().any(char::is_control) {
            return Err(invalid("invalid Git filter key"));
        }
        command.arg("-c").arg(format!(
            "{key}={}",
            if key.ends_with(".required") {
                "false"
            } else {
                ""
            }
        ));
    }
    command.args(args);
    run(&mut command, deadline, diff)
}
fn git_text(path: &Path, args: &[&str], deadline: Instant) -> io::Result<String> {
    let data = git(path, args, deadline, false)?;
    Ok(String::from_utf8(data)
        .map_err(|_| invalid("Git metadata is not UTF-8"))?
        .trim_end_matches('\n')
        .into())
}
fn oid(text: &str) -> bool {
    matches!(text.len(), 40 | 64) && text.bytes().all(|b| b.is_ascii_hexdigit())
}
fn hash(parts: &[&[u8]]) -> String {
    let mut digest = Sha256::new();
    for part in parts {
        digest.update((part.len() as u64).to_be_bytes());
        digest.update(part);
    }
    digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
struct Snapshot {
    text: String,
    version: String,
    head: String,
    clean: bool,
}
impl Snapshot {
    fn value(&self, record: &AgentRecord) -> Value {
        json!({"version":self.version,"text":self.text,"headOid":self.head,"createdAtMs":record.created_at_ms})
    }
}
fn snapshot(record: &AgentRecord, deadline: Instant) -> io::Result<Snapshot> {
    let path = record
        .worktree
        .as_ref()
        .map_or(record.cwd.as_path(), |w| w.path.as_path());
    let head = git_text(path, &["rev-parse", "--verify", "HEAD^{commit}"], deadline)?;
    if !oid(&head) {
        return Err(invalid("invalid local HEAD"));
    }
    let base = record
        .worktree
        .as_ref()
        .map_or(head.as_str(), |w| w.base.as_str());
    if !oid(base) {
        return Err(invalid("invalid review base"));
    }
    let target = match &record.worktree {
        Some(w) => git_text(
            &w.repo,
            &["rev-parse", "--verify", "HEAD^{commit}"],
            deadline,
        )?,
        None => head.clone(),
    };
    let mut data = git(
        path,
        &[
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--binary",
            base,
            "--",
        ],
        deadline,
        false,
    )?;
    let files = git(
        path,
        &["ls-files", "--others", "--exclude-standard", "-z"],
        deadline,
        false,
    )?;
    let files: Vec<_> = files.split(|b| *b == 0).filter(|p| !p.is_empty()).collect();
    if files.len() > 200 {
        return Err(invalid("too many untracked files for review"));
    }
    for file in files {
        let name = std::str::from_utf8(file).map_err(|_| invalid("untracked path is not UTF-8"))?;
        let added = git(
            path,
            &[
                "diff",
                "--no-index",
                "--no-ext-diff",
                "--no-textconv",
                "--no-color",
                "--binary",
                "--",
                "/dev/null",
                name,
            ],
            deadline,
            true,
        )?;
        if data.len() + added.len() > LIMIT {
            return Err(invalid("diff exceeds size limit"));
        }
        data.extend(added);
    }
    let status = git(
        path,
        &["status", "--porcelain=v1", "--untracked-files=all"],
        deadline,
        false,
    )?;
    // A Git write concurrent with capture cannot silently change HEAD or the target base.
    if git_text(path, &["rev-parse", "--verify", "HEAD^{commit}"], deadline)? != head
        || record.worktree.as_ref().is_some_and(|w| {
            git_text(
                &w.repo,
                &["rev-parse", "--verify", "HEAD^{commit}"],
                deadline,
            )
            .map_or(true, |current| current != target)
        })
    {
        return Err(invalid("HEAD changed while reviewing; refresh the diff"));
    }
    let identity = serde_json::to_vec(&json!({"id":record.id,"createdAtMs":record.created_at_ms,
        "cwd":record.cwd,"project":record.project_dir(),"worktree":record.worktree}))?;
    let version = hash(&[
        b"trama-review-v1",
        &identity,
        head.as_bytes(),
        base.as_bytes(),
        target.as_bytes(),
        &data,
    ]);
    let text = String::from_utf8(data).map_err(|_| invalid("diff is not UTF-8"))?;
    Ok(Snapshot {
        text,
        version,
        head,
        clean: status.is_empty(),
    })
}
pub(super) fn diff_snapshot(record: &AgentRecord) -> io::Result<Value> {
    Ok(snapshot(record, Instant::now() + DEADLINE)?.value(record))
}

// Coordinates are lines in the complete returned diff, not file line numbers. Track hunk
// counts so a source line beginning +++ or --- remains commentable inside a hunk.
fn commentable(text: &str) -> BTreeSet<usize> {
    fn count(range: &str, sign: char) -> Option<usize> {
        let range = range.strip_prefix(sign)?;
        let (start, count) = range.split_once(',').unwrap_or((range, "1"));
        start.parse::<usize>().ok()?;
        count.parse().ok()
    }
    let mut old = 0usize;
    let mut new = 0usize;
    let mut lines = BTreeSet::new();
    for (index, line) in text.split('\n').enumerate() {
        if line.starts_with("@@ ") {
            let fields: Vec<_> = line.split_whitespace().collect();
            (old, new) = fields
                .get(1)
                .and_then(|v| count(v, '-'))
                .zip(fields.get(2).and_then(|v| count(v, '+')))
                .unwrap_or((0, 0));
        } else {
            let valid = match line.as_bytes().first() {
                Some(b' ') if old > 0 && new > 0 => {
                    old -= 1;
                    new -= 1;
                    true
                }
                Some(b'-') if old > 0 => {
                    old -= 1;
                    true
                }
                Some(b'+') if new > 0 => {
                    new -= 1;
                    true
                }
                Some(b'\\') => false,
                _ => {
                    old = 0;
                    new = 0;
                    false
                }
            };
            if valid {
                lines.insert(index + 1);
            }
        }
    }
    lines
}
fn review(
    record: &AgentRecord,
    request: &Request,
) -> io::Result<(Snapshot, String, String, usize)> {
    if request.created_at_ms != Some(record.created_at_ms) {
        return Err(invalid("agent identity changed; refresh the diff"));
    }
    let snapshot = snapshot(record, Instant::now() + DEADLINE)?;
    if request.expected_version.as_deref() != Some(snapshot.version.as_str()) {
        return Err(invalid("review is obsolete; refresh the diff"));
    }
    let notes = request
        .notes
        .as_ref()
        .ok_or_else(|| invalid("notes are required"))?;
    if notes.is_empty() || notes.len() > 32 {
        return Err(invalid("review requires 1..32 notes"));
    }
    let anchors = commentable(&snapshot.text);
    let mut text = format!("Review notes for diff {}\n", snapshot.version);
    for note in notes {
        if !anchors.contains(&note.line) {
            return Err(invalid("review line must reference content in a diff hunk"));
        }
        if note.body.trim().is_empty()
            || note
                .body
                .chars()
                .any(|c| c.is_control() && c != '\n' && c != '\t')
        {
            return Err(invalid(
                "review note is empty or contains terminal controls",
            ));
        }
        // Include enough of the exact anchor for the provider to locate it without reconstructing
        // the UI's global diff numbering. Source text is quoted and terminal controls are escaped.
        let mut file = "";
        let mut hunk = "";
        let mut source = "";
        for line in snapshot.text.split('\n').take(note.line) {
            if line.starts_with("diff --git ") {
                file = line;
            }
            if line.starts_with("@@ ") {
                hunk = line;
            }
            source = line;
        }
        let context = |value: &str| -> io::Result<String> {
            let escaped: String = value
                .chars()
                .map(|c| {
                    if c.is_control() {
                        c.escape_unicode().to_string()
                    } else {
                        c.to_string()
                    }
                })
                .collect();
            Ok(serde_json::to_string(&escaped)?)
        };
        text.push_str(&format!(
            "\nDiff line {}:\nFile: {}\nHunk: {}\nSource: {}\n{}\n",
            note.line,
            context(file)?,
            context(hunk)?,
            context(source)?,
            note.body
        ));
        if text.len() + 13 > INPUT_LIMIT {
            return Err(invalid("review input exceeds 24000 bytes"));
        }
    }
    let token = hash(&[
        b"trama-review-delivery-v1",
        &record.id.to_be_bytes(),
        &record.created_at_ms.to_be_bytes(),
        snapshot.version.as_bytes(),
        text.as_bytes(),
    ]);
    Ok((snapshot, text, token, notes.len()))
}
pub(super) fn review_preview(
    store: &Store,
    record: &AgentRecord,
    request: &Request,
) -> io::Result<Value> {
    if m3::is_archived(store, record.id) {
        return Err(invalid("archived worktrees cannot receive review notes"));
    }
    let (snapshot, text, token, count) = review(record, request)?;
    Ok(
        json!({"text":text,"token":token,"version":snapshot.version,"createdAtMs":record.created_at_ms,"noteCount":count}),
    )
}
pub(super) fn send_review(
    store: &Store,
    record: &AgentRecord,
    request: &Request,
) -> io::Result<Value> {
    if request.confirmed != Some(true) {
        return Err(invalid("explicit review confirmation is required"));
    }
    if m3::is_archived(store, record.id) {
        return Err(invalid("archived worktrees cannot receive review notes"));
    }
    if !record.kind.is_ai() {
        return Err(invalid(
            "review delivery requires an AI provider, never a shell",
        ));
    }
    let (snapshot, text, token, count) = review(record, request)?;
    if request.review_token.as_deref() != Some(token.as_str()) {
        return Err(invalid(
            "review preview changed; preview the exact batch again",
        ));
    }
    let status = match cli::probe(store, record.id) {
        Probe::Live(status)
            if matches!(
                status.state,
                orkai::model::AgentState::Idle | orkai::model::AgentState::Done
            ) && status.running_kind(record.kind) == record.kind
                && status.exit.is_none() =>
        {
            status
        }
        _ => {
            return Err(invalid(
                "wait for the same AI provider to be idle or done at its prompt; approvals are not bypassed",
            ));
        }
    };
    let _ = status;
    if store.load_agent(record.id)? != *record {
        return Err(invalid("agent identity changed; refresh the diff"));
    }
    let runtime = store
        .read_runtime(record.id)?
        .ok_or_else(|| invalid("agent is not running"))?;
    let payload = format!("\x1b[200~{text}\x1b[201~\r");
    // A single transport delivery, never a retry. Success acknowledges transport only.
    client::deliver(&runtime, &ClientMsg::Input(payload.into_bytes()))?;
    Ok(
        json!({"agentId":record.id,"createdAtMs":record.created_at_ms,"version":snapshot.version,"noteCount":count,"deliveredToPTY":true}),
    )
}

fn repository(remote: &str) -> io::Result<String> {
    let path = remote
        .strip_prefix("https://github.com/")
        .or_else(|| remote.strip_prefix("git@github.com:"))
        .or_else(|| remote.strip_prefix("ssh://git@github.com/"))
        .ok_or_else(|| invalid("origin must use github.com HTTPS or Git SSH"))?;
    let path = path.strip_suffix(".git").unwrap_or(path);
    let parts: Vec<_> = path.split('/').collect();
    if parts.len() != 2
        || parts.iter().any(|part| {
            part.is_empty()
                || *part == "."
                || *part == ".."
                || part.starts_with('-')
                || !part
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        })
    {
        return Err(invalid("origin must identify one GitHub owner/repository"));
    }
    Ok(path.into())
}
pub(super) fn github_pr(record: &AgentRecord, request: &Request) -> io::Result<Value> {
    if request.confirmed != Some(true) {
        return Err(invalid(
            "explicit GitHub network and credential confirmation is required",
        ));
    }
    if request.created_at_ms != Some(record.created_at_ms) {
        return Err(invalid(
            "agent identity changed; select the current agent before querying GitHub",
        ));
    }
    if request.number == Some(0) {
        return Err(invalid("pull request number must be positive"));
    }
    let deadline = Instant::now() + DEADLINE;
    let path = record
        .worktree
        .as_ref()
        .map_or(record.cwd.as_path(), |w| w.path.as_path());
    let remote = git_text(path, &["config", "--get", "remote.origin.url"], deadline)?;
    let repo = repository(&remote)?;
    let branch = git_text(
        path,
        &["symbolic-ref", "--quiet", "--short", "HEAD"],
        deadline,
    )?;
    if branch.is_empty()
        || branch.len() > 255
        || branch.starts_with('-')
        || branch.chars().any(char::is_control)
    {
        return Err(invalid("invalid local branch"));
    }
    let local = snapshot(record, deadline)?;
    let selector = request
        .number
        .map_or_else(|| branch.clone(), |n| n.to_string());
    let program = orkai::launch::resolve_program("gh")?;
    let mut command = Command::new(program);
    for key in [
        "GH_HOST",
        "GH_REPO",
        "GH_DEBUG",
        "DEBUG",
        "GH_FORCE_TTY",
        "GH_PATH",
        "GH_PAGER",
        "PAGER",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
    ] {
        command.env_remove(key);
    }
    command
        .current_dir(storeless_directory())
        .args([
            "pr",
            "view",
            &selector,
            "--repo",
            &format!("github.com/{repo}"),
            "--json",
            "number,url,title,state,headRefName,headRefOid,statusCheckRollup,isCrossRepository",
        ])
        .env("GH_HOST", "github.com")
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env("GH_NO_EXTENSION_UPDATE_NOTIFIER", "1")
        .env("GH_TELEMETRY", "0")
        .env("NO_COLOR", "1");
    let bytes = run(&mut command, deadline, false)?;
    let value: Value =
        serde_json::from_slice(&bytes).map_err(|_| invalid("invalid GitHub response"))?;
    let number = value["number"]
        .as_u64()
        .filter(|n| *n > 0 && *n <= u32::MAX as u64)
        .ok_or_else(|| invalid("invalid GitHub PR number"))?;
    let url = value["url"]
        .as_str()
        .ok_or_else(|| invalid("missing GitHub PR URL"))?;
    let head = value["headRefOid"]
        .as_str()
        .filter(|v| oid(v))
        .ok_or_else(|| invalid("invalid GitHub head SHA"))?;
    if request.number.is_some_and(|n| u64::from(n) != number)
        || url != format!("https://github.com/{repo}/pull/{number}")
        || value["headRefName"] != branch
        || value["isCrossRepository"] != false
    {
        return Err(invalid(
            "GitHub PR does not match the local repository and branch",
        ));
    }
    let title = value["title"]
        .as_str()
        .filter(|s| safe_label(s, 1024))
        .ok_or_else(|| invalid("invalid GitHub title"))?;
    let state = value["state"]
        .as_str()
        .filter(|s| ["OPEN", "CLOSED", "MERGED"].contains(s))
        .ok_or_else(|| invalid("invalid GitHub PR state"))?;
    let checks = match value.get("statusCheckRollup") {
        None | Some(Value::Null) => vec![],
        Some(Value::Array(checks)) if checks.len() <= 100 => checks
            .iter()
            .map(|check| {
                let name = check["name"]
                    .as_str()
                    .or_else(|| check["context"].as_str())
                    .filter(|s| safe_label(s, 512))
                    .ok_or_else(|| invalid("invalid GitHub check name"))?;
                let state = check["status"]
                    .as_str()
                    .or_else(|| check["state"].as_str())
                    .filter(|s| safe_label(s, 64))
                    .ok_or_else(|| invalid("invalid GitHub check state"))?;
                let conclusion = match check.get("conclusion") {
                    None | Some(Value::Null) => None,
                    Some(Value::String(s)) if s.is_empty() || safe_label(s, 64) => Some(s.as_str()),
                    _ => return Err(invalid("invalid GitHub check conclusion")),
                };
                Ok(json!({"name":name,"state":state,"conclusion":conclusion}))
            })
            .collect::<io::Result<Vec<_>>>()?,
        _ => return Err(invalid("invalid or excessive GitHub checks")),
    };
    // Detect a local edit made during the network read instead of assigning this result to it.
    let final_deadline = Instant::now() + DEADLINE;
    if git_text(
        path,
        &["symbolic-ref", "--quiet", "--short", "HEAD"],
        final_deadline,
    )? != branch
        || repository(&git_text(
            path,
            &["config", "--get", "remote.origin.url"],
            final_deadline,
        )?)? != repo
        || snapshot(record, final_deadline)?.version != local.version
    {
        return Err(invalid(
            "local review changed during GitHub query; query again manually",
        ));
    }
    Ok(
        json!({"number":number,"url":url,"title":title,"state":state,"repository":repo,"branch":branch,"headOid":head,
        "localHeadOid":local.head,"matchesLocalHead":head == local.head,"localDiffEmpty":local.clean,"diffVersion":local.version,"checks":checks,"queriedAtMs":orkai::util::now_ms()}),
    )
}
fn storeless_directory() -> &'static Path {
    Path::new("/")
}
fn safe_label(text: &str, limit: usize) -> bool {
    !text.is_empty() && text.len() <= limit && !text.chars().any(char::is_control)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn hunk_anchor_vector_matches_swift() {
        let text = "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1,2 +1,2 @@\n--- old source\n+++ new source\n unchanged\n\\ No newline at end of file\n@@ -4,0 +5 @@\n+added\nnot a hunk\n+outside\n";
        assert_eq!(commentable(text), BTreeSet::from([5, 6, 7, 10]));
        assert!(commentable("--- a\n+++ b\n@@ broken @@\n+outside\n").is_empty());
    }
}
