//! Compare bounded history with the pinned upstream transcript on local log fixtures.
//! No holder, provider executable, credentials, or network is used.
use orkai::{
    holder::oplog::OutputLog,
    model::{AgentKind, NewAgent},
    paths::Home,
    protocol::TermSize,
    store::Store,
};
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    path::PathBuf,
    process::{Command, Stdio},
};

struct Fixture {
    root: PathBuf,
    store: Store,
    id: u32,
}

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "trama-memory-test-{}",
            orkai::util::new_uuid_v4().unwrap()
        ));
        let store = Store::open(Home::at(root.clone())).unwrap();
        let record = store
            .create_agent(NewAgent {
                name: "controlled-history".into(),
                kind: AgentKind::Terminal,
                cwd: root.clone(),
                task: String::new(),
                session: "default".into(),
            })
            .unwrap();
        Self {
            root,
            store,
            id: record.id,
        }
    }

    fn log(&self, rows: u16, cols: u16, max_bytes: u64) -> OutputLog {
        OutputLog::open_with_limit(
            self.store.home().output_log(self.id),
            TermSize::new(rows, cols),
            max_bytes,
        )
        .unwrap()
    }

    fn compare(&self) -> (String, bool) {
        let full = orkai::cli::transcript(&self.store, self.id)
            .unwrap()
            .unwrap_or_default()
            .join("\n");
        let original_start = full.len().saturating_sub(65_536);
        let mut start = original_start;
        while !full.is_char_boundary(start) {
            start += 1;
        }
        let mut child = Command::new(env!("CARGO_BIN_EXE_trama-engine"))
            .args(["--request", "--home"])
            .arg(&self.root)
            .env_clear()
            .env("HOME", &self.root)
            .env("PATH", "/usr/bin:/bin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        serde_json::to_writer(
            child.stdin.take().unwrap(),
            &json!({"operation":"logs","agentId":self.id}),
        )
        .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let response: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(response["ok"], true);
        assert_eq!(
            response["result"],
            json!({"text":&full[start..],"truncated":start > 0})
        );
        assert!(response["result"]["text"].as_str().unwrap().len() <= 65_536);
        (full, start != original_start)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).unwrap();
    }
}

#[test]
fn bounded_history_matches_upstream_blank_ansi_resize_and_alternate_screen() {
    let absent = Fixture::new();
    assert_eq!(absent.compare().0, "");
    let empty = Fixture::new();
    {
        empty
            .log(20, 80, u64::MAX)
            .output(b"\r\n\r\n  \r\n")
            .unwrap();
    }
    assert_eq!(empty.compare().0, "");
    let fixture = Fixture::new();
    {
        let mut log = fixture.log(20, 80, u64::MAX);
        log.output("first\u{2003}  \r\n\r\nthird\r\n\r\n".as_bytes())
            .unwrap();
        log.output(b"\x1b[31mred\x1b[0m\r\nold text\r\x1b[2Knew text\r\n")
            .unwrap();
        log.output(b"\x1b[?1049halternate screen\r\n\x1b[?1049lback\r\n")
            .unwrap();
        log.resize(TermSize::new(4, 20)).unwrap();
        log.output("ação 👩🏽‍💻\r\n\r\nlast  \r\n\r\n".as_bytes())
            .unwrap();
    }
    let full = fixture.compare().0;
    assert!(
        full.contains("\n\n"),
        "fixture must exercise preserved internal empty rows"
    );
    assert!(!full.ends_with('\n'));
    let alternate = Fixture::new();
    {
        alternate
            .log(20, 80, u64::MAX)
            .output(b"normal\r\n\x1b[?1049halternate still active\r\nlast")
            .unwrap();
    }
    assert!(alternate.compare().0.contains("alternate still active"));
}

#[test]
fn bounded_history_matches_upstream_at_unicode_cut_and_rotated_or_incomplete_logs() {
    let mut cuts_inside_utf8 = 0;
    for suffix_length in 0..4 {
        let fixture = Fixture::new();
        {
            let mut log = fixture.log(100, 240, 200_000);
            for _ in 0..2 {
                let content = format!("{}\r\n", "éç界".repeat(55)).repeat(1000);
                log.output(content.as_bytes()).unwrap();
            }
            log.output(format!("{}\r\n\r\n", "z".repeat(suffix_length)).as_bytes())
                .unwrap();
        }
        let (full, cut_inside) = fixture.compare();
        assert!(full.len() > 65_536);
        cuts_inside_utf8 += usize::from(cut_inside);
        assert!(
            orkai::holder::oplog::rotated_path(&fixture.store.home().output_log(fixture.id))
                .exists()
        );
        // A partial final record remains tolerated by the upstream replay contract.
        fs::OpenOptions::new()
            .append(true)
            .open(fixture.store.home().output_log(fixture.id))
            .unwrap()
            .write_all(&[1, 50, 0, 0, 0, b'x'])
            .unwrap();
        fixture.compare();
    }
    assert!(
        cuts_inside_utf8 > 0,
        "fixture must cut within a multibyte character"
    );
}

#[test]
fn bounded_history_preserves_exact_limit_and_newline_boundaries() {
    for total in [65_535, 65_536, 65_537, 65_520, 65_521] {
        let fixture = Fixture::new();
        let row = format!("{}\r\n", "x".repeat(239));
        let complete_rows = (total - 1) / 240;
        let final_bytes = total - complete_rows * 240;
        {
            let mut log = fixture.log(100, 240, u64::MAX);
            log.output(
                format!("{}{}", row.repeat(complete_rows), "z".repeat(final_bytes)).as_bytes(),
            )
            .unwrap();
        }
        assert_eq!(fixture.compare().0.len(), total);
    }
}
