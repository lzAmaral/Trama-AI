//! Explicit text delivery to an already running provider. No launch, shell, or retry.
use super::*;
use orkai::{
    model::{AgentState, StatusReport},
    protocol::HolderMsg,
};
use std::net::TcpStream;

const INPUT_LIMIT: usize = 24_000;
const WRAPPER_BYTES: usize = 13;
const STATUS_FRAME_LIMIT: usize = 64 * 1024;
const STATUS_TOTAL_LIMIT: usize = 256 * 1024;

/// Bounded framing over the upstream authenticated connection. A partial available frame
/// must finish before the absolute deadline; it cannot hide a later approval/state delta.
struct StatusObservation {
    pending: Vec<u8>,
    total: usize,
    deadline: Instant,
    latest: Option<StatusReport>,
}

impl StatusObservation {
    fn new() -> Self {
        Self {
            pending: Vec::new(),
            total: 0,
            deadline: Instant::now() + Duration::from_millis(1500),
            latest: None,
        }
    }

    fn drain(&mut self, reader: &TcpStream) -> io::Result<&StatusReport> {
        let mut chunk = [0u8; 8192];
        loop {
            if Instant::now() >= self.deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "provider status deadline",
                ));
            }
            let mut consumed = 0;
            while self.pending.len() - consumed >= 4 {
                if Instant::now() >= self.deadline {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "provider status deadline",
                    ));
                }
                let len =
                    u32::from_le_bytes(self.pending[consumed..consumed + 4].try_into().unwrap())
                        as usize;
                if !(1..=STATUS_FRAME_LIMIT).contains(&len) {
                    return Err(invalid("provider status frame exceeds size limit"));
                }
                if self.pending.len() - consumed < len + 4 {
                    break;
                }
                let kind = self.pending[consumed + 4];
                let payload = self.pending[consumed + 5..consumed + 4 + len].to_vec();
                match HolderMsg::from_frame(kind, payload)? {
                    HolderMsg::Status(status) => self.latest = Some(status),
                    HolderMsg::Output(_) => {}
                    HolderMsg::Exited(_) => {
                        return Err(invalid("exited agents cannot receive prompts"));
                    }
                    _ => return Err(invalid("unexpected provider status frame")),
                }
                consumed += len + 4;
            }
            self.pending.drain(..consumed);
            // MSG_DONTWAIT leaves the shared socket's blocking flags unchanged for Input/finish.
            let received = unsafe {
                libc::recv(
                    reader.as_raw_fd(),
                    chunk.as_mut_ptr().cast(),
                    chunk.len(),
                    libc::MSG_DONTWAIT,
                )
            };
            if received > 0 {
                self.total += received as usize;
                if self.total > STATUS_TOTAL_LIMIT {
                    return Err(invalid("provider status stream exceeds size limit"));
                }
                self.pending.extend_from_slice(&chunk[..received as usize]);
                continue;
            }
            if received == 0 {
                return Err(invalid("provider connection closed before prompt delivery"));
            }
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            if error.kind() != io::ErrorKind::WouldBlock {
                return Err(error);
            }
            if self.pending.is_empty() && self.latest.is_some() {
                break;
            }
            let remaining = self.deadline.saturating_duration_since(Instant::now());
            let mut descriptor = libc::pollfd {
                fd: reader.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            let waited = unsafe {
                libc::poll(
                    &mut descriptor,
                    1,
                    remaining.as_millis().clamp(1, i32::MAX as u128) as i32,
                )
            };
            if waited < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                return Err(io::Error::last_os_error());
            }
        }
        self.latest
            .as_ref()
            .ok_or_else(|| invalid("current provider status is unavailable"))
    }
}

pub(super) fn send_prompt(
    store: &Store,
    record: &AgentRecord,
    request: &Request,
) -> io::Result<Value> {
    if request.confirmed != Some(true) {
        return Err(invalid("explicit prompt confirmation is required"));
    }
    if request.created_at_ms != Some(record.created_at_ms) {
        return Err(invalid("agent identity changed; select the current agent"));
    }
    let text = request
        .message
        .as_deref()
        .ok_or_else(|| invalid("message is required"))?;
    // Rust is_control is Unicode Cc, matching Swift's generalCategory .control;
    // format characters such as ZWJ/ZWNJ remain literal prompt text.
    if text.trim().is_empty()
        || text
            .chars()
            .any(|c| c.is_control() && c != '\n' && c != '\t')
    {
        return Err(invalid("prompt is empty or contains terminal controls"));
    }
    if text.len() > INPUT_LIMIT - WRAPPER_BYTES {
        return Err(invalid(
            "prompt input including wrappers exceeds 24000 bytes",
        ));
    }
    if !record.kind.is_ai() {
        return Err(invalid(
            "prompt delivery requires an AI provider, never a shell",
        ));
    }
    validate_record(store, record)?;
    let runtime = store
        .read_runtime(record.id)?
        .ok_or_else(|| invalid("agent is not running"))?;
    // Authenticate once, then keep this exact connection for both the status and input.
    // Do not acquire the global metadata lock: GitHub/list may hold it for seconds.
    let (connection, reader, welcome) = client::connect(&runtime)?;
    if welcome.agent_id != record.id || welcome.holder_pid != runtime.holder_pid {
        return Err(invalid("terminal holder identity changed"));
    }
    let mut observation = StatusObservation::new();
    observation.drain(&reader)?;
    validate_record(store, record)?;
    if store.read_runtime(record.id)?.as_ref() != Some(&runtime) {
        return Err(invalid(
            "terminal holder identity changed before prompt delivery",
        ));
    }
    let payload = format!("\x1b[200~{text}\x1b[201~\r");
    // Re-read all currently available complete deltas after filesystem validation.
    let status = observation.drain(&reader)?;
    if !matches!(status.state, AgentState::Idle | AgentState::Done)
        || status.running_kind(record.kind) != record.kind
        || status.exit.is_some()
    {
        return Err(invalid(
            "wait for the same AI provider to be idle or done at its prompt; approvals are not bypassed",
        ));
    }
    // Completing a fragmented final frame may wait: validate metadata once more afterwards.
    validate_record(store, record)?;
    if store.read_runtime(record.id)?.as_ref() != Some(&runtime) {
        return Err(invalid(
            "terminal holder identity changed before prompt delivery",
        ));
    }
    // Residual TOCTOU: the provider can change after this last observation and before Input.
    // Upstream has no atomic conditional input/state gate; draining is not that guarantee.
    connection.send(&ClientMsg::Input(payload.into_bytes()))?;
    connection.finish(reader)?;
    // This is a transport acknowledgment, never proof of provider processing or success.
    Ok(json!({"agentId":record.id,"createdAtMs":record.created_at_ms,"deliveredToPTY":true}))
}

fn validate_record(store: &Store, record: &AgentRecord) -> io::Result<()> {
    if store.load_agent(record.id)? != *record {
        return Err(invalid("agent identity changed before prompt delivery"));
    }
    if m3::is_archived(store, record.id) {
        return Err(invalid("archived worktrees cannot receive prompts"));
    }
    if store.read_exit(record.id)?.is_some() {
        return Err(invalid("exited agents cannot receive prompts"));
    }
    Ok(())
}
