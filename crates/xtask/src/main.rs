//! Repository tasks: `cargo xtask release <tag> <commit>`.
//!
//! `release` publishes a release by pushing the tag `release.yml` runs on. It
//! refuses unless the tag is new and the commit is on `origin/main`, and it
//! waits for the commit's `ci.yml` run to pass first, because `release.yml`
//! publishes the files that run built and fails without them.

use std::process::{Command, ExitCode};
use std::time::{Duration, Instant};
use std::{env, thread};

const CI_WORKFLOW: &str = "ci.yml";
const BRANCH: &str = "origin/main";
const POLL: Duration = Duration::from_secs(15);
/// How long to wait for CI to start a run for the commit.
const NO_RUN_GRACE: Duration = Duration::from_secs(5 * 60);
const CI_TIMEOUT: Duration = Duration::from_secs(90 * 60);

const USAGE: &str = "usage: cargo xtask release <tag> <commit>

  <tag>     v<major>.<minor>.<patch>[-<prerelease>], e.g. v0.1.0
  <commit>  the commit to release; any git revision, resolved to a full hash";

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    let result = match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
        ["release", tag, commit] => release(tag, commit),
        _ => {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("error: {message}");
            ExitCode::FAILURE
        }
    }
}

fn release(tag: &str, commit: &str) -> Result<(), String> {
    if !is_release_tag(tag) {
        return Err(format!(
            "{tag:?} is not a release tag: release.yml runs on \
             v<major>.<minor>.<patch>[-<prerelease>]"
        ));
    }
    git(&["fetch", "--quiet", "origin"])?;
    let sha = git(&[
        "rev-parse",
        "--verify",
        "--quiet",
        &format!("{commit}^{{commit}}"),
    ])
    .map_err(|_| format!("{commit:?} is not a commit in this repository"))?;
    println!("commit {sha}");

    check_tag_is_new(tag)?;
    match status("git", &["merge-base", "--is-ancestor", &sha, BRANCH])? {
        Some(0) => {}
        Some(1) => return Err(format!("{sha} is not on {BRANCH}")),
        _ => return Err(format!("could not compare {sha} with {BRANCH}")),
    }

    wait_for_ci(&sha)?;

    // CI can take an hour; someone else may have tagged in the meantime.
    check_tag_is_new(tag)?;
    git(&["tag", "--annotate", "--message", tag, tag, &sha])?;
    git(&["push", "origin", &format!("refs/tags/{tag}")])?;
    println!("pushed {tag} at {sha}; release.yml publishes it");
    Ok(())
}

/// Whether `tag` is `v<major>.<minor>.<patch>` with an optional `-<prerelease>`.
fn is_release_tag(tag: &str) -> bool {
    let Some(version) = tag.strip_prefix('v') else {
        return false;
    };
    let (core, prerelease) = match version.split_once('-') {
        Some((core, prerelease)) => (core, Some(prerelease)),
        None => (version, None),
    };
    let parts: Vec<&str> = core.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
        && prerelease.is_none_or(|p| {
            !p.is_empty()
                && p.bytes().all(|b| {
                    b.is_ascii_alphanumeric() || b == b'.' || b == b'-'
                })
        })
}

fn check_tag_is_new(tag: &str) -> Result<(), String> {
    let reference = format!("refs/tags/{tag}");
    if status("git", &["rev-parse", "--verify", "--quiet", &reference])?
        == Some(0)
    {
        return Err(format!("tag {tag} already exists locally"));
    }
    if !git(&["ls-remote", "--tags", "origin", &reference])?.is_empty() {
        return Err(format!("tag {tag} already exists on origin"));
    }
    Ok(())
}

/// Blocks until the latest `ci.yml` run for `sha` succeeds; fails if it fails.
fn wait_for_ci(sha: &str) -> Result<(), String> {
    let start = Instant::now();
    loop {
        let latest = capture(
            "gh",
            &[
                "run",
                "list",
                "--workflow",
                CI_WORKFLOW,
                "--commit",
                sha,
                "--limit",
                "1",
                "--json",
                "databaseId,status,conclusion",
                "--jq",
                r#".[0] // empty | "\(.databaseId) \(.status) \(.conclusion)""#,
            ],
        )?;
        let fields: Vec<&str> = latest.split_whitespace().collect();
        match fields[..] {
            [] if start.elapsed() > NO_RUN_GRACE => {
                return Err(format!("no {CI_WORKFLOW} run for {sha}"));
            }
            [] => println!("waiting for {CI_WORKFLOW} to start for {sha}"),
            [id, "completed", "success"] => {
                println!("CI run {id} passed");
                return Ok(());
            }
            [id, "completed", conclusion] => {
                return Err(format!("CI run {id} finished: {conclusion}"));
            }
            [id, state, ..] => println!("CI run {id}: {state}"),
            _ => return Err(format!("unexpected gh output: {latest:?}")),
        }
        if start.elapsed() > CI_TIMEOUT {
            return Err(format!(
                "CI for {sha} did not finish in {CI_TIMEOUT:?}"
            ));
        }
        thread::sleep(POLL);
    }
}

fn git(args: &[&str]) -> Result<String, String> {
    capture("git", args)
}

/// Runs a command in the repository root and returns its trimmed stdout.
fn capture(program: &str, args: &[&str]) -> Result<String, String> {
    let output = command(program, args)
        .output()
        .map_err(|e| format!("could not run {program}: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "{program} {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

/// Runs a command in the repository root and returns its exit code.
fn status(program: &str, args: &[&str]) -> Result<Option<i32>, String> {
    command(program, args)
        .output()
        .map(|output| output.status.code())
        .map_err(|e| format!("could not run {program}: {e}"))
}

fn command(program: &str, args: &[&str]) -> Command {
    let mut command = Command::new(program);
    command
        .args(args)
        .current_dir(concat!(env!("CARGO_MANIFEST_DIR"), "/../.."));
    command
}

#[cfg(test)]
mod tests {
    use super::is_release_tag;

    #[test]
    fn accepts_release_tags() {
        for tag in ["v0.1.0", "v10.20.30", "v1.0.0-rc.1", "v1.0.0-beta-2"] {
            assert!(is_release_tag(tag), "{tag}");
        }
    }

    #[test]
    fn rejects_other_tags() {
        for tag in [
            "0.1.0",
            "v1",
            "v1.2",
            "v1.2.3.4",
            "v1.2.x",
            "v1.2.3-",
            "v1.2.3-a_b",
            "v",
        ] {
            assert!(!is_release_tag(tag), "{tag}");
        }
    }
}
