//! Background jobs. Every button that takes more than a moment (Claude calls, the edit pipeline)
//! runs here and shows a live status line, a log, and a Stop button.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

use crate::dates::now_secs;

const LOG_LINES: usize = 400;

#[derive(Clone)]
pub struct JobState {
    id: String,
    kind: String,
    label: String,
    state: String,
    step: String,
    detail: String,
    started: u64,
    finished: Option<u64>,
    result: Option<Value>,
    error: Option<String>,
    pids: Vec<u32>,
    cancelled: bool,
    cost: f64,
    log: Vec<String>,
}

fn jobs() -> &'static Mutex<HashMap<String, JobState>> {
    static JOBS: OnceLock<Mutex<HashMap<String, JobState>>> = OnceLock::new();
    JOBS.get_or_init(|| Mutex::new(HashMap::new()))
}

static NEXT_JOB: AtomicU64 = AtomicU64::new(1);

fn new_state(id: &str, kind: &str, label: &str) -> JobState {
    JobState {
        id: id.to_string(),
        kind: kind.to_string(),
        label: label.to_string(),
        state: "running".into(),
        step: "Starting".into(),
        detail: String::new(),
        started: now_secs(),
        finished: None,
        result: None,
        error: None,
        pids: vec![],
        cancelled: false,
        cost: 0.0,
        log: vec![],
    }
}

#[derive(Clone)]
pub struct Job {
    pub id: String,
}

impl Job {
    fn with<F: FnOnce(&mut JobState)>(&self, f: F) {
        if let Ok(mut m) = jobs().lock() {
            if let Some(j) = m.get_mut(&self.id) {
                f(j);
            }
        }
    }
    pub fn step(&self, s: &str) {
        self.with(|j| {
            j.step = s.to_string();
            j.detail = String::new();
        });
    }
    pub fn detail(&self, s: &str) {
        let s: String = s.chars().take(140).collect();
        self.with(|j| j.detail = s);
    }
    pub fn log(&self, line: &str) {
        let line = line.to_string();
        self.with(|j| {
            j.log.push(line);
            if j.log.len() > LOG_LINES {
                j.log.remove(0);
            }
        });
    }
    pub fn add_pid(&self, pid: u32) {
        self.with(|j| j.pids.push(pid));
    }
    pub fn remove_pid(&self, pid: u32) {
        self.with(|j| j.pids.retain(|p| *p != pid));
    }
    pub fn add_cost(&self, c: f64) {
        self.with(|j| j.cost += c);
    }
    pub fn is_cancelled(&self) -> bool {
        jobs().lock().ok().and_then(|m| m.get(&self.id).map(|j| j.cancelled)).unwrap_or(false)
    }
    /// A throwaway job for tests and synchronous callers.
    pub fn detached(label: &str) -> Job {
        let id = format!("t{}", NEXT_JOB.fetch_add(1, Ordering::SeqCst));
        if let Ok(mut m) = jobs().lock() {
            m.insert(id.clone(), new_state(&id, "detached", label));
        }
        Job { id }
    }
}

pub fn start_job<F>(kind: &str, label: &str, f: F) -> String
where
    F: FnOnce(&Job) -> Result<Value, String> + Send + 'static,
{
    let id = format!("j{}", NEXT_JOB.fetch_add(1, Ordering::SeqCst));
    if let Ok(mut m) = jobs().lock() {
        m.insert(id.clone(), new_state(&id, kind, label));
    }
    let job = Job { id: id.clone() };
    std::thread::spawn(move || {
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| f(&job)))
            .unwrap_or_else(|_| Err("Something crashed inside Studio.".to_string()));
        job.with(|j| {
            j.finished = Some(now_secs());
            match &r {
                Ok(v) => {
                    j.state = "done".into();
                    j.result = Some(v.clone());
                }
                Err(e) => {
                    j.state = if j.cancelled { "stopped".into() } else { "error".into() };
                    j.error = Some(e.clone());
                }
            }
        });
    });
    id
}

pub fn job_json(id: &str) -> Result<Value, String> {
    let m = jobs().lock().map_err(|e| e.to_string())?;
    let j = m.get(id).ok_or_else(|| "No such job".to_string())?;
    Ok(json!({
        "id": j.id, "kind": j.kind, "label": j.label, "state": j.state, "step": j.step,
        "detail": j.detail, "started": j.started, "finished": j.finished,
        "elapsed": j.finished.unwrap_or_else(now_secs).saturating_sub(j.started),
        "result": j.result, "error": j.error, "cost_usd": (j.cost * 100.0).round() / 100.0,
        "log": j.log,
    }))
}

pub fn stop_job(id: &str) -> Result<(), String> {
    let pids = {
        let mut m = jobs().lock().map_err(|e| e.to_string())?;
        let j = m.get_mut(id).ok_or("No such job")?;
        j.cancelled = true;
        j.step = "Stopping".into();
        j.pids.clone()
    };
    for p in pids {
        kill_tree(p);
    }
    Ok(())
}

/// Stops a process and the children it started (spawned as their own process group).
fn kill_tree(pid: u32) {
    #[cfg(unix)]
    {
        let group = format!("-{pid}");
        if !Command::new("kill").arg("-TERM").arg("--").arg(&group).status().map(|s| s.success()).unwrap_or(false) {
            let _ = Command::new("kill").arg("-TERM").arg(pid.to_string()).status();
        }
    }
    #[cfg(not(unix))]
    {
        let _ = Command::new("taskkill").args(["/PID", &pid.to_string(), "/T", "/F"]).status();
    }
}

/// Runs a command, streams every output line into the job log, and returns the exit code.
pub fn run_logged(job: &Job, mut cmd: Command) -> Result<i32, String> {
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped()).stdin(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }
    let mut child = cmd.spawn().map_err(|e| format!("Couldn't start the command: {e}"))?;
    job.add_pid(child.id());
    let mut readers = Vec::new();
    if let Some(out) = child.stdout.take() {
        let j = job.clone();
        readers.push(std::thread::spawn(move || pump(out, &j)));
    }
    if let Some(err) = child.stderr.take() {
        let j = job.clone();
        readers.push(std::thread::spawn(move || pump(err, &j)));
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    for r in readers {
        let _ = r.join();
    }
    job.remove_pid(child.id());
    if job.is_cancelled() {
        return Err("Stopped.".to_string());
    }
    Ok(status.code().unwrap_or(-1))
}

fn pump<R: std::io::Read>(r: R, job: &Job) {
    for line in BufReader::new(r).lines().map_while(Result::ok) {
        let line = line.trim_end().to_string();
        if !line.is_empty() {
            job.detail(&line);
            job.log(&line);
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn output_lines_reach_the_log_and_the_exit_code_is_returned() {
        let job = Job::detached("t");
        let mut cmd = Command::new("sh");
        cmd.args(["-c", "echo one; echo two 1>&2; exit 3"]);
        assert_eq!(run_logged(&job, cmd).unwrap(), 3);
        let j = job_json(&job.id).unwrap();
        let log: Vec<String> = j["log"].as_array().unwrap().iter().map(|l| l.as_str().unwrap().to_string()).collect();
        assert!(log.contains(&"one".to_string()) && log.contains(&"two".to_string()));
    }

    #[test]
    fn stop_ends_a_running_command() {
        let id = start_job("test", "sleeper", |job| {
            let mut cmd = Command::new("sh");
            cmd.args(["-c", "echo started; sleep 30"]);
            run_logged(job, cmd).map(|c| json!({"code": c}))
        });
        for _ in 0..100 {
            let j = job_json(&id).unwrap();
            if j["log"].as_array().is_some_and(|l| !l.is_empty()) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        stop_job(&id).unwrap();
        for _ in 0..100 {
            if job_json(&id).unwrap()["state"] != "running" {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        assert_eq!(job_json(&id).unwrap()["state"], "stopped");
    }
}
