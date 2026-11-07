//! Local Trama operations layered over the pinned upstream Store and transcript replay.
//! No Hub, Peer, provider credentials, provider transcript discovery or provider network access.
use super::*;
use orkai::{fsutil, model::Session};
use serde::Serialize;
use std::{collections::HashSet, fs, os::unix::fs::MetadataExt, path::Path};

const RENAME_JOURNAL: &str = "trama-session-rename.json";
const RETENTION_PLAN: &str = "trama-log-retention.json";
const LOG_FILES: [&str; 4] = ["output.log", "output.log.1", "holder.log", "test.log"];

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RenameJournal {
    old: RenameState,
    new: RenameState,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RenameState {
    name: String,
    records: Vec<AgentRecord>,
    sessions: Vec<Session>,
}

fn regular_metadata(path: &Path) -> io::Result<Option<fs::Metadata>> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.is_file() && !meta.file_type().is_symlink() => Ok(Some(meta)),
        Ok(_) => Err(invalid(
            "expected a regular local file; symlinks are not supported",
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

pub(super) fn records(store: &Store) -> io::Result<Vec<AgentRecord>> {
    // Upstream list_agents deliberately skips unreadable/corrupt records. A session mutation or
    // cleanup preview must instead preserve and report such data, never operate on a partial list.
    let mut records = Vec::new();
    for entry in fs::read_dir(store.home().agents_dir())? {
        let entry = entry?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.bytes().all(|b| b.is_ascii_digit()) || name.is_empty() {
            continue;
        }
        let id: u32 = name
            .parse()
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid agent directory"))?;
        if name != id.to_string() || !entry.file_type()?.is_dir() {
            return Err(invalid(
                "agent directories must be regular local directories",
            ));
        }
        let path = store.home().agent_file(id);
        regular_metadata(&path)?
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing agent record"))?;
        let record: AgentRecord = fsutil::read_json(&path)?;
        if record.id != id {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "agent identity mismatch",
            ));
        }
        records.push(record);
        if records.len() > MAX_AGENTS {
            return Err(invalid("this version supports at most 64 stored agents"));
        }
    }
    records.sort_by_key(|r| r.id);
    Ok(records)
}

pub(super) fn recover_rename(store: &Store) -> io::Result<()> {
    let path = store.home().root().join(RENAME_JOURNAL);
    if regular_metadata(&path)?.is_none() {
        return Ok(());
    }
    let journal: RenameJournal = fsutil::read_json(&path)?;
    let current = records(store)?;
    // Fail closed on an invalid journal; never overwrite it with inferred/default state.
    let valid_state = |state: &RenameState| {
        let names: HashSet<_> = state.sessions.iter().map(|s| s.name.as_str()).collect();
        let ids: HashSet<_> = state.records.iter().map(|r| r.id).collect();
        state.records.len() <= MAX_AGENTS
            && !state.sessions.is_empty()
            && names.len() == state.sessions.len()
            && ids.len() == state.records.len()
            && names.contains(state.name.as_str())
            && state.sessions.iter().all(|s| {
                orkai::model::validate_session_name(&s.name).ok().as_ref() == Some(&s.name)
            })
            && state.records.iter().all(|r| {
                r.id != 0
                    && r.session == state.name
                    && orkai::model::validate_agent_name(&r.name).ok().as_ref() == Some(&r.name)
                    && r.cwd.is_absolute()
                    && !r.bypass
                    && !r.remote_control
            })
    };
    let old = &journal.old;
    let new = &journal.new;
    if !valid_state(old)
        || !valid_state(new)
        || old.name == new.name
        || old.sessions.iter().any(|s| s.name == new.name)
        || new.sessions.iter().any(|s| s.name == old.name)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid rename journal",
        ));
    }
    let mut expected_records = old.records.clone();
    for record in &mut expected_records {
        record.session = new.name.clone();
    }
    let mut expected_sessions = old.sessions.clone();
    for session in &mut expected_sessions {
        if session.name == old.name {
            session.name = new.name.clone();
        }
    }
    regular_metadata(&store.home().sessions_file())?
        .ok_or_else(|| invalid("rename journal requires its original session snapshot"))?;
    let saved: orkai::model::SessionList = fsutil::read_json(&store.home().sessions_file())?;
    let affected: Vec<_> = current
        .iter()
        .filter(|r| r.session == old.name || r.session == new.name)
        .collect();
    if expected_records != new.records
        || expected_sessions != new.sessions
        || (saved.sessions != old.sessions && saved.sessions != new.sessions)
        || affected.len() != old.records.len()
        || !old.records.iter().zip(&new.records).all(|(before, after)| {
            affected
                .iter()
                .any(|record| **record == *before || **record == *after)
        })
        || current.iter().any(|r| {
            !old.sessions
                .iter()
                .chain(&new.sessions)
                .any(|s| s.name == r.session)
        })
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "rename journal does not match stored metadata",
        ));
    }
    // Roll forward idempotently. All metadata readers and writers hold the same mutation lock.
    for record in &new.records {
        store.save_agent(record)?;
    }
    store.save_sessions(&new.sessions)?;
    fs::remove_file(path)
}

pub(super) fn rename_session(store: &Store, request: &Request) -> io::Result<Value> {
    let old = request
        .session
        .as_deref()
        .ok_or_else(|| invalid("session is required"))?;
    let new = orkai::model::validate_session_name(
        request
            .name
            .as_deref()
            .ok_or_else(|| invalid("name is required"))?,
    )
    .map_err(|_| invalid("invalid session name"))?;
    let mut records = records(store)?;
    if records.len() > MAX_AGENTS {
        return Err(invalid("this version supports at most 64 stored agents"));
    }
    let mut sessions = store.peek_sessions_with(&records)?.0;
    if !sessions.iter().any(|s| s.name == old) {
        return Err(invalid("source session does not exist"));
    }
    if old == new {
        return Ok(json!({}));
    }
    if sessions.iter().any(|s| s.name == new) {
        return Err(invalid("destination session already exists"));
    }
    // LaunchSpec captures ORKAI_SESSION in the child environment. A running child could otherwise
    // recreate the old grouping through upstream __agents; Lost is not proof the child exited.
    records.retain(|r| r.session == old);
    if records
        .iter()
        .any(|r| !matches!(cli::probe(store, r.id), Probe::Exited(_)))
    {
        return Err(invalid("stop all agents in the session before renaming it"));
    }
    let original = RenameState {
        name: old.into(),
        records: records.clone(),
        sessions: sessions.clone(),
    };
    for session in &mut sessions {
        if session.name == old {
            session.name = new.clone();
        }
    }
    for record in &mut records {
        if record.session == old {
            record.session = new.clone();
        }
    }
    // Materialize inferred sessions before journaling, so recovery can verify either complete
    // session snapshot without guessing defaults or timestamps after a crash.
    store.save_sessions(&original.sessions)?;
    fsutil::write_json_atomic(
        &store.home().root().join(RENAME_JOURNAL),
        &RenameJournal {
            old: original,
            new: RenameState {
                name: new,
                records,
                sessions,
            },
        },
    )?;
    recover_rename(store)?;
    Ok(json!({}))
}

pub(super) fn move_agent(
    store: &Store,
    mut record: AgentRecord,
    request: &Request,
) -> io::Result<Value> {
    let session = request
        .session
        .as_deref()
        .ok_or_else(|| invalid("session is required"))?;
    let records = records(store)?;
    if !store
        .peek_sessions_with(&records)?
        .0
        .iter()
        .any(|s| s.name == session)
    {
        return Err(invalid("destination session does not exist"));
    }
    if records
        .iter()
        .any(|r| r.id != record.id && r.session == session && r.name == record.name)
    {
        return Err(invalid("agent name already exists in destination session"));
    }
    if record.session == session {
        return Ok(json!({}));
    }
    if !matches!(cli::probe(store, record.id), Probe::Exited(_)) {
        return Err(invalid(
            "stop the agent before moving it to another session",
        ));
    }
    record.session = session.into();
    store.save_agent(&record)?;
    Ok(json!({}))
}

fn archive_path(store: &Store, id: u32) -> PathBuf {
    store
        .home()
        .agent_dir(id)
        .join("trama-worktree-archive.json")
}

pub(super) fn is_archived(store: &Store, id: u32) -> bool {
    // Even an unreadable or malformed marker must prevent a resume/modification.
    fs::symlink_metadata(archive_path(store, id)).is_ok()
}

pub(super) fn archive_worktree(
    store: &Store,
    record: &AgentRecord,
    request: &Request,
) -> io::Result<Value> {
    if request.confirmed != Some(true) {
        return Err(invalid("explicit archive confirmation is required"));
    }
    if !matches!(cli::probe(store, record.id), Probe::Exited(_)) {
        return Err(invalid("stop the agent before archiving its worktree"));
    }
    let worktree = record
        .worktree
        .as_ref()
        .ok_or_else(|| invalid("agent has no isolated worktree"))?;
    if !worktree.path.is_dir() {
        return Err(invalid("worktree directory is missing"));
    }
    let path = archive_path(store, record.id);
    if regular_metadata(&path)?.is_some() {
        let archive: Value = fsutil::read_json(&path)?;
        return Ok(archive);
    }
    // Archiving is a durable, read-only marker. No Git add/commit/remove, file move or deletion:
    // staged, unstaged, untracked and ignored files, Git history and branch all stay intact.
    let archive = json!({"agentId":record.id,"path":worktree.path,"branch":worktree.branch,
        "archivedAtMs":orkai::util::now_ms(),"preservesChanges":true});
    fsutil::write_json_atomic(&path, &archive)?;
    Ok(archive)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProcessNode {
    pid: u32,
    parent_pid: Option<u32>,
    name: String,
    kind: Option<String>,
}

fn process_name(pid: u32) -> String {
    #[cfg(target_os = "macos")]
    {
        let mut bytes = [0u8; 256];
        let len =
            unsafe { libc::proc_name(pid as i32, bytes.as_mut_ptr().cast(), bytes.len() as u32) };
        String::from_utf8_lossy(&bytes[..(len.max(0) as usize).min(bytes.len())])
            .trim_end_matches('\0')
            .into()
    }
    #[cfg(not(target_os = "macos"))]
    {
        fs::read_to_string(format!("/proc/{pid}/comm"))
            .unwrap_or_default()
            .trim()
            .into()
    }
}

fn child_pids(pid: u32) -> Vec<u32> {
    #[cfg(target_os = "macos")]
    {
        let mut children = [0i32; 256];
        let count = unsafe {
            libc::proc_listchildpids(
                pid as i32,
                children.as_mut_ptr().cast(),
                std::mem::size_of_val(&children) as i32,
            )
        };
        // proc_listchildpids returns a PID count (unlike proc_listpids, which returns bytes).
        let count = count.max(0) as usize;
        children[..count.min(children.len())]
            .iter()
            .filter_map(|p| u32::try_from(*p).ok().filter(|p| *p > 0))
            .collect()
    }
    #[cfg(not(target_os = "macos"))]
    {
        fs::read_to_string(format!("/proc/{pid}/task/{pid}/children"))
            .unwrap_or_default()
            .split_whitespace()
            .filter_map(|p| p.parse().ok())
            .collect()
    }
}

pub(super) fn process_tree(store: &Store, record: &AgentRecord) -> io::Result<Value> {
    let runtime = if matches!(cli::probe(store, record.id), Probe::Live(_)) {
        store.read_runtime(record.id)?
    } else {
        None
    };
    let root = runtime.and_then(|r| r.child_pid);
    let mut nodes = Vec::new();
    let mut queue = std::collections::VecDeque::new();
    if let Some(pid) = root {
        queue.push_back((pid, None));
    }
    let mut seen = HashSet::new();
    while let Some((pid, parent_pid)) = queue.pop_front() {
        if !seen.insert(pid) {
            continue;
        }
        let name = process_name(pid);
        if name.is_empty() {
            continue;
        }
        let program = orkai::holder::nested::program_name(&name);
        let kind = AgentKind::parse(&program)
            .filter(|k| k.is_ai())
            .map(|k| k.label().to_string());
        nodes.push(ProcessNode {
            pid,
            parent_pid,
            name,
            kind,
        });
        if nodes.len() >= 256 {
            break;
        }
        for child in child_pids(pid) {
            if queue.len() < 256 {
                queue.push_back((child, Some(pid)));
            }
        }
    }
    Ok(
        json!({"agentId":record.id,"rootPid":root,"nodes":nodes,"complete":false,
        "limitations":["Local process snapshot only; processes can exit or change during observation.",
        "At most 256 visible processes; permissions and OS visibility can omit descendants.",
        "Process names are hints, not proof of logical subagents; remote and in-process agents are not observable."],
        "observedAtMs":orkai::util::now_ms()}),
    )
}

pub(super) fn logs(store: &Store, id: u32) -> io::Result<Value> {
    let path = store.home().output_log(id);
    for candidate in [&path, &orkai::holder::oplog::rotated_path(&path)] {
        if regular_metadata(candidate)?.is_some_and(|meta| meta.len() > 16 * 1024 * 1024) {
            return Err(invalid("recorded log exceeds replay limit"));
        }
    }
    let text = cli::transcript(store, id)?.unwrap_or_default().join("\n");
    let mut start = text.len().saturating_sub(65_536);
    while !text.is_char_boundary(start) {
        start += 1;
    }
    Ok(json!({"text":&text[start..],"truncated":start > 0}))
}

pub(super) fn export_logs(store: &Store, id: u32, request: &Request) -> io::Result<Value> {
    if request.confirmed != Some(true) {
        return Err(invalid("explicit log export confirmation is required"));
    }
    let redactions = request.redactions.as_deref().unwrap_or_default();
    if redactions.len() > 32
        || redactions.iter().any(|r| r.is_empty() || r.len() > 1024)
        || redactions.iter().map(String::len).sum::<usize>() > 8192
    {
        return Err(invalid(
            "redactions must contain at most 32 nonempty strings, 1024 bytes each and 8192 bytes total",
        ));
    }
    let log = logs(store, id)?;
    let mut text = log["text"].as_str().unwrap_or_default().to_string();
    // Apply the longest strings first so a shorter prefix does not defeat a longer redaction.
    let mut ordered: Vec<_> = redactions.iter().collect();
    ordered.sort_by_key(|r| std::cmp::Reverse(r.len()));
    for redaction in ordered {
        // Never expand text: each match becomes one Unicode block (or asterisk for 1-2 bytes).
        text = text.replace(
            redaction.as_str(),
            if redaction.len() >= 3 { "█" } else { "*" },
        );
    }
    Ok(
        json!({"text":text,"truncated":log["truncated"],"requiresSensitiveReview":true,
        "warning":"Review this exact preview before saving or sharing. Literal redactions do not guarantee removal of secrets or personal data; terminal replay may omit older output."}),
    )
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Candidate {
    path: String,
    bytes: u64,
    // Identity stays in the private plan, not in the RPC preview.
    device: u64,
    inode: u64,
    modified: i64,
    modified_ns: i64,
    changed: i64,
    changed_ns: i64,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RetentionPlan {
    plan_token: String,
    max_age_days: Option<u32>,
    max_file_bytes: Option<u64>,
    evaluated_at_ms: u64,
    candidates: Vec<Candidate>,
}

fn candidates(
    store: &Store,
    days: Option<u32>,
    bytes: Option<u64>,
    now: u64,
) -> io::Result<Vec<Candidate>> {
    let records = records(store)?;
    if records.len() > MAX_AGENTS {
        return Err(invalid("this version supports at most 64 stored agents"));
    }
    let mut result = Vec::new();
    for record in records {
        if !matches!(cli::probe(store, record.id), Probe::Exited(_)) {
            continue;
        }
        let dir = store.home().agent_dir(record.id);
        let directory = fs::symlink_metadata(&dir)?;
        if !directory.is_dir() || directory.file_type().is_symlink() {
            continue;
        }
        for file in LOG_FILES {
            let path = dir.join(file);
            let meta = match fs::symlink_metadata(&path) {
                Ok(meta) if meta.is_file() && !meta.file_type().is_symlink() => meta,
                Ok(_) => continue,
                Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error),
            };
            let modified_ms = u64::try_from(meta.mtime())
                .unwrap_or(u64::MAX)
                .saturating_mul(1000);
            let old = days
                .is_some_and(|days| modified_ms < now.saturating_sub(u64::from(days) * 86_400_000));
            let large = bytes.is_some_and(|limit| meta.len() > limit);
            if old || large {
                result.push(Candidate {
                    path: format!("agents/{}/{file}", record.id),
                    bytes: meta.len(),
                    device: meta.dev(),
                    inode: meta.ino(),
                    modified: meta.mtime(),
                    modified_ns: meta.mtime_nsec(),
                    changed: meta.ctime(),
                    changed_ns: meta.ctime_nsec(),
                });
            }
        }
    }
    result.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(result)
}

pub(super) fn retention_plan(store: &Store, request: &Request) -> io::Result<Value> {
    if request.max_age_days.is_none() && request.max_file_bytes.is_none()
        || request
            .max_age_days
            .is_some_and(|d| !(1..=3650).contains(&d))
        || request
            .max_file_bytes
            .is_some_and(|b| b > 1024 * 1024 * 1024)
    {
        return Err(invalid(
            "specify maxAgeDays 1..3650 and/or maxFileBytes 0..1073741824 (per file)",
        ));
    }
    let now = orkai::util::now_ms();
    let plan = RetentionPlan {
        plan_token: orkai::util::new_uuid_v4()?,
        max_age_days: request.max_age_days,
        max_file_bytes: request.max_file_bytes,
        evaluated_at_ms: now,
        candidates: candidates(store, request.max_age_days, request.max_file_bytes, now)?,
    };
    fsutil::write_json_atomic(&store.home().root().join(RETENTION_PLAN), &plan)?;
    Ok(
        json!({"planToken":plan.plan_token,"maxAgeDays":plan.max_age_days,"maxFileBytes":plan.max_file_bytes,
        "candidates":plan.candidates.iter().map(|c| json!({"path":c.path,"bytes":c.bytes})).collect::<Vec<_>>(),
        "totalBytes":plan.candidates.iter().map(|c| c.bytes).sum::<u64>()}),
    )
}

pub(super) fn apply_retention(store: &Store, request: &Request) -> io::Result<Value> {
    if request.confirmed != Some(true) {
        return Err(invalid("explicit log retention confirmation is required"));
    }
    let token = request
        .plan_token
        .as_deref()
        .ok_or_else(|| invalid("planToken is required"))?;
    let path = store.home().root().join(RETENTION_PLAN);
    if regular_metadata(&path)?.is_none() {
        return Err(invalid("retention plan is missing; review a new plan"));
    }
    let plan: RetentionPlan = fsutil::read_json(&path)?;
    // Compare every candidate and state before removing the first file, including identity/mtime/ctime.
    // Recompute paths from trusted IDs and fixed filenames rather than deleting paths supplied by JSON.
    let current = candidates(
        store,
        plan.max_age_days,
        plan.max_file_bytes,
        plan.evaluated_at_ms,
    )?;
    if plan.plan_token != token || current != plan.candidates {
        return Err(invalid(
            "retention plan is obsolete; review a new plan before deleting logs",
        ));
    }
    for candidate in &current {
        fs::remove_file(store.home().root().join(&candidate.path)).map_err(|_| {
            invalid("log cleanup could be partial; review a new plan before retrying")
        })?;
    }
    fs::remove_file(path)
        .map_err(|_| invalid("logs were cleaned but the plan could not be cleared; review a new plan before retrying"))?;
    Ok(
        json!({"removedFiles":current.len(),"removedBytes":current.iter().map(|c| c.bytes).sum::<u64>()}),
    )
}
