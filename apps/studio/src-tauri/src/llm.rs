//! Every LLM call goes through the user's own `claude` CLI (`claude -p`). No API keys.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Command, Stdio};

use crate::jobs::Job;

/// A GUI-launched macOS app does not inherit the Terminal's PATH, so look in the usual places.
pub fn resolve_claude_binary() -> String {
    // Tests point this at a fake script.
    if let Ok(b) = std::env::var("STUDIO_CLAUDE_BIN") {
        if !b.is_empty() {
            return b;
        }
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let candidates = [
        "/opt/homebrew/bin/claude".to_string(),
        "/usr/local/bin/claude".to_string(),
        format!("{home}/.claude/local/claude"),
        format!("{home}/.local/bin/claude"),
        "/usr/bin/claude".to_string(),
    ];
    candidates.into_iter().find(|c| Path::new(c).exists()).unwrap_or_else(|| "claude".to_string())
}

/// PATH for spawned tools: `claude` and the studio launcher may themselves start node, git, python.
pub fn gui_path() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let base = format!("/opt/homebrew/bin:/usr/local/bin:{home}/.claude/local:{home}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin");
    match std::env::var("PATH") {
        Ok(p) if !p.is_empty() => format!("{base}:{p}"),
        _ => base,
    }
}

fn base_command(schema: &str, allowed_tools: &str, model: &str, format: &str) -> Command {
    let mut cmd = Command::new(resolve_claude_binary());
    cmd.arg("-p").arg("--output-format").arg(format);
    if format == "stream-json" {
        cmd.arg("--verbose");
    }
    if !allowed_tools.is_empty() {
        cmd.arg("--allowedTools").arg(allowed_tools);
    }
    if !model.is_empty() {
        cmd.arg("--model").arg(model);
    }
    cmd.arg("--json-schema").arg(schema).env("PATH", gui_path());
    cmd
}

/// The prompt goes in on stdin, so a long prompt never hits the command-line size limit.
fn feed_prompt(child: &mut std::process::Child, prompt: &str) {
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(prompt.as_bytes());
    }
}

fn launch_error(bin: &str, e: std::io::Error) -> String {
    format!("Couldn't run claude ({bin}): {e}. Is Claude Code installed and logged in?")
}

pub fn run_claude_structured(schema: &str, prompt: &str, allowed_tools: &str, model: &str) -> Result<Value, String> {
    let mut cmd = base_command(schema, allowed_tools, model, "json");
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| launch_error(&resolve_claude_binary(), e))?;
    feed_prompt(&mut child, prompt);
    let output = child.wait_with_output().map_err(|e| e.to_string())?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let reason = serde_json::from_str::<Value>(&stdout)
            .ok()
            .and_then(|v| v.get("result").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_else(|| stdout.chars().rev().take(400).collect::<Vec<_>>().into_iter().rev().collect());
        return Err(format!("Claude stopped with an error: {} {}", stderr.trim(), reason.trim()));
    }
    let parsed: Value = serde_json::from_str(&stdout).map_err(|e| format!("Couldn't read Claude's answer: {e}"))?;
    if parsed.get("is_error").and_then(Value::as_bool).unwrap_or(false) {
        let msg = parsed.get("result").and_then(Value::as_str).unwrap_or("unknown error");
        return Err(format!("Claude reported an error: {msg}"));
    }
    parsed.get("structured_output").cloned().ok_or_else(|| "Claude's answer had no structured output.".to_string())
}

/// The streaming version, used for everything started from a button: the status line says what
/// Claude is doing right now instead of a spinner that looks frozen.
pub fn run_claude_stream(schema: &str, prompt: &str, allowed_tools: &str, model: &str, job: &Job) -> Result<Value, String> {
    let mut cmd = base_command(schema, allowed_tools, model, "stream-json");
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }
    let mut child = cmd.spawn().map_err(|e| launch_error(&resolve_claude_binary(), e))?;
    job.add_pid(child.id());
    feed_prompt(&mut child, prompt);

    let stderr = child.stderr.take();
    let err_thread = std::thread::spawn(move || {
        let mut s = String::new();
        if let Some(mut e) = stderr {
            let _ = std::io::Read::read_to_string(&mut e, &mut s);
        }
        s
    });

    let mut result: Option<Value> = None;
    if let Some(out) = child.stdout.take() {
        for line in BufReader::new(out).lines().map_while(Result::ok) {
            let Ok(ev) = serde_json::from_str::<Value>(&line) else { continue };
            match ev.get("type").and_then(Value::as_str) {
                Some("assistant") => {
                    for p in ev.pointer("/message/content").and_then(Value::as_array).into_iter().flatten() {
                        match p.get("type").and_then(Value::as_str) {
                            Some("tool_use") => {
                                let name = p.get("name").and_then(Value::as_str).unwrap_or("");
                                job.detail(&match name {
                                    "StructuredOutput" => "Writing it down".to_string(),
                                    other => format!("Using {other}"),
                                });
                            }
                            Some("thinking") => job.detail("Thinking"),
                            Some("text") => job.detail("Writing"),
                            _ => {}
                        }
                    }
                }
                Some("result") => {
                    if ev.get("is_error").and_then(Value::as_bool).unwrap_or(false) {
                        let msg = ev.get("result").and_then(Value::as_str).unwrap_or("unknown error").to_string();
                        result = Some(json!({"__error": msg}));
                    } else if let Some(so) = ev.get("structured_output") {
                        result = Some(so.clone());
                    }
                    if let Some(c) = ev.get("total_cost_usd").and_then(Value::as_f64) {
                        job.add_cost(c);
                    }
                }
                _ => {}
            }
        }
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    job.remove_pid(child.id());
    let err_text = err_thread.join().unwrap_or_default();
    if job.is_cancelled() {
        return Err("Stopped.".to_string());
    }
    match result {
        Some(v) if v.get("__error").is_some() => Err(format!("Claude reported an error: {}", v["__error"].as_str().unwrap_or(""))),
        Some(v) => Ok(v),
        None => Err(format!("Claude finished without an answer (exit {status}). {}", err_text.trim())),
    }
}

/// One Claude call for a job: streams progress, returns the structured answer.
pub fn ask(job: &Job, schema: &str, prompt: &str, model: &str) -> Result<Value, String> {
    run_claude_stream(schema, prompt, "", model, job)
}
