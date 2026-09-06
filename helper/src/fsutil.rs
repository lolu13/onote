//! Process and file primitives shaped the way the marketplace review expects:
//! child output is capped at the producer under a deadline and the whole
//! process group is killed on overflow; files are created exclusively at mode
//! 0600 and published by rename; reads never follow a symlink or block on a
//! FIFO. Everything here is Linux-only, like the plugin.
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

pub fn euid() -> u32 {
    // SAFETY: geteuid has no preconditions and cannot fail.
    unsafe { libc::geteuid() }
}

fn kill_group(child: &mut Child) {
    let pgid = child.id() as libc::pid_t;
    // SAFETY: the child was spawned with process_group(0), so its pid is the
    // group id of everything it started; signalling that group cannot reach
    // any other process of ours.
    unsafe { libc::killpg(pgid, libc::SIGTERM) };
    let until = Instant::now() + Duration::from_millis(300);
    while Instant::now() < until {
        if matches!(child.try_wait(), Ok(Some(_))) {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    unsafe { libc::killpg(pgid, libc::SIGKILL) };
    let _ = child.wait();
}

pub enum Bounded {
    /// Exit status 0 and at most `max` bytes.
    Ok(Vec<u8>),
    /// The command failed, produced nothing, or exited non-zero.
    Failed,
    /// More than `max` bytes, or the deadline passed; the group was killed.
    TooLarge,
    TimedOut,
}

/// Runs `argv` in its own process group with an empty stdin, reading at most
/// `max` bytes of stdout (one more to detect overflow). stderr is discarded.
pub fn run_bounded(argv: &[&str], max: usize, deadline: Duration) -> Bounded {
    let mut child = match Command::new(argv[0])
        .args(&argv[1..])
        .process_group(0)
        .env_clear()
        .envs(minimal_env())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => return Bounded::Failed,
    };
    let stdout = child.stdout.take().expect("piped");
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let r = stdout.take(max as u64 + 1).read_to_end(&mut buf);
        let _ = tx.send(r.map(|_| buf));
    });
    match rx.recv_timeout(deadline) {
        Ok(Ok(buf)) if buf.len() > max => {
            kill_group(&mut child);
            Bounded::TooLarge
        }
        Ok(Ok(buf)) => match child.wait() {
            Ok(s) if s.success() => Bounded::Ok(buf),
            _ => Bounded::Failed,
        },
        Ok(Err(_)) => {
            kill_group(&mut child);
            Bounded::Failed
        }
        Err(_) => {
            kill_group(&mut child);
            Bounded::TimedOut
        }
    }
}

/// Feeds `input` to `argv` on stdin (stdout and stderr discarded) and waits up
/// to `deadline` for it to exit. A child that is still running afterwards is
/// left alone and reaped in the background: wl-copy stays alive to serve the
/// clipboard when built without forking, and killing it would empty it.
pub fn feed_detached(argv: &[&str], input: &[u8], deadline: Duration) -> Result<(), String> {
    let mut child = Command::new(argv[0])
        .args(&argv[1..])
        .process_group(0)
        .env_clear()
        .envs(minimal_env())
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("{}: {e}", argv[0]))?;
    let mut stdin = child.stdin.take().ok_or("no stdin")?;
    let owned = input.to_vec();
    let mut writer = Some(std::thread::spawn(move || stdin.write_all(&owned).and_then(|_| stdin.flush())));
    let until = Instant::now() + deadline;
    let mut written = None;
    while Instant::now() < until {
        if writer.as_ref().is_some_and(|w| w.is_finished()) {
            written = Some(writer.take().expect("checked").join().map_err(|_| "writer panicked".to_string())?);
        }
        if let Ok(Some(status)) = child.try_wait() {
            if let Some(Err(e)) = written {
                return Err(format!("{}: {e}", argv[0]));
            }
            return if status.success() { Ok(()) } else { Err(format!("{} exited with {status}", argv[0])) };
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

/// The environment a child gets: enough to find the Wayland socket and the
/// Hyprland instance, nothing inherited that could redirect it.
fn minimal_env() -> Vec<(String, String)> {
    ["HOME", "XDG_RUNTIME_DIR", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE"]
        .iter()
        .filter_map(|k| std::env::var(k).ok().map(|v| (k.to_string(), v)))
        .chain(std::iter::once(("PATH".to_string(), "/usr/bin".to_string())))
        .collect()
}

/// A directory the current user owns (symlinks followed for the user's own
/// chosen folders such as a vault). Created when missing.
pub fn ensure_owned_dir(dir: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    let meta = std::fs::metadata(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    if !meta.is_dir() || meta.uid() != euid() {
        return Err(format!("{} is not a directory owned by this user", dir.display()));
    }
    Ok(())
}

/// The plugin's own state directory: a real directory (no symlink), owned by
/// this user, mode 0700, repaired on every launch.
pub fn ensure_private_dir(dir: &Path) -> Result<(), String> {
    match std::fs::symlink_metadata(dir) {
        Ok(m) if m.file_type().is_symlink() => return Err(format!("{} is a symlink", dir.display())),
        Ok(m) if !m.is_dir() => return Err(format!("{} is not a directory", dir.display())),
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(dir)
                .map_err(|e| format!("create {}: {e}", dir.display()))?;
        }
        Err(e) => return Err(format!("{}: {e}", dir.display())),
    }
    let meta = std::fs::metadata(dir).map_err(|e| e.to_string())?;
    if meta.uid() != euid() {
        return Err(format!("{} is owned by another user", dir.display()));
    }
    if meta.permissions().mode() & 0o077 != 0 {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Makes an existing regular file of ours 0600. Missing files are fine.
pub fn make_private(path: &Path) -> Result<(), String> {
    match std::fs::symlink_metadata(path) {
        Ok(m) if m.file_type().is_symlink() => Err(format!("{} is a symlink", path.display())),
        Ok(m) if !m.is_file() => Err(format!("{} is not a regular file", path.display())),
        Ok(m) if m.uid() != euid() => Err(format!("{} is owned by another user", path.display())),
        Ok(m) if m.permissions().mode() & 0o077 != 0 => {
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())
        }
        Ok(_) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

/// Creates an empty 0600 file unless something already exists at `path`.
pub fn create_private_if_missing(path: &Path) -> Result<(), String> {
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
    {
        Ok(_) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
        Err(e) => Err(format!("create {}: {e}", path.display())),
    }
}

/// Reads at most `max` bytes from a regular file this user owns, without
/// following a symlink or blocking on a FIFO. None when the path is missing
/// or anything else.
pub fn read_owned_head(path: &Path, max: usize) -> Option<Vec<u8>> {
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.uid() != euid() {
        return None;
    }
    let mut buf = Vec::new();
    file.take(max as u64).read_to_end(&mut buf).ok()?;
    Some(buf)
}

fn write_temp(dir: &Path, name_hint: &str, data: &[u8]) -> Result<std::path::PathBuf, String> {
    let tmp = dir.join(format!(".{}.{}.tmp", name_hint, uuid::Uuid::new_v4().simple()));
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&tmp)
        .map_err(|e| format!("create {}: {e}", tmp.display()))?;
    let done = f.write_all(data).and_then(|_| f.sync_all());
    if let Err(e) = done {
        let _ = std::fs::remove_file(&tmp);
        return Err(format!("write {}: {e}", tmp.display()));
    }
    Ok(tmp)
}

fn sync_dir(dir: &Path) {
    if let Ok(d) = std::fs::File::open(dir) {
        let _ = d.sync_all();
    }
}

/// Writes `data` to `path` through an exclusive 0600 temporary in the same
/// directory and a rename, which replaces a planted symlink at `path` rather
/// than writing through it.
pub fn write_private_atomic(path: &Path, data: &[u8]) -> Result<(), String> {
    let dir = path.parent().ok_or("no parent directory")?;
    let hint = path.file_name().and_then(|n| n.to_str()).unwrap_or("file");
    let tmp = write_temp(dir, hint, data)?;
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(format!("rename to {}: {e}", path.display()));
    }
    sync_dir(dir);
    Ok(())
}

/// Like `write_private_atomic`, but fails instead of replacing anything that
/// exists at `path` (RENAME_NOREPLACE, so there is no check-then-act window).
pub fn write_private_new(path: &Path, data: &[u8]) -> Result<(), String> {
    use std::os::unix::ffi::OsStrExt;
    let dir = path.parent().ok_or("no parent directory")?;
    let hint = path.file_name().and_then(|n| n.to_str()).unwrap_or("file");
    let tmp = write_temp(dir, hint, data)?;
    let from = std::ffi::CString::new(tmp.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
    let to = std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
    // SAFETY: both paths are valid NUL-terminated C strings that outlive the call.
    let rc = unsafe { libc::renameat2(libc::AT_FDCWD, from.as_ptr(), libc::AT_FDCWD, to.as_ptr(), libc::RENAME_NOREPLACE) };
    if rc != 0 {
        let e = std::io::Error::last_os_error();
        let _ = std::fs::remove_file(&tmp);
        return Err(format!("rename to {}: {e}", path.display()));
    }
    sync_dir(dir);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir() -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("desknotes-fsutil-{}-{}", std::process::id(), uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn bounded_run_caps_bytes_and_time() {
        match run_bounded(&["/usr/bin/head", "-c", "10", "/dev/zero"], 100, Duration::from_secs(5)) {
            Bounded::Ok(b) => assert_eq!(b.len(), 10),
            _ => panic!("small output should pass"),
        }
        assert!(matches!(run_bounded(&["/usr/bin/cat", "/dev/zero"], 4096, Duration::from_secs(5)), Bounded::TooLarge));
        let t = Instant::now();
        assert!(matches!(run_bounded(&["/usr/bin/sleep", "30"], 10, Duration::from_millis(200)), Bounded::TimedOut));
        assert!(t.elapsed() < Duration::from_secs(3), "the group was killed, not waited for");
        assert!(matches!(run_bounded(&["/usr/bin/false"], 10, Duration::from_secs(5)), Bounded::Failed));
        assert!(matches!(run_bounded(&["/nonexistent/binary"], 10, Duration::from_secs(5)), Bounded::Failed));
    }

    #[test]
    fn atomic_write_replaces_a_planted_symlink_instead_of_writing_through_it() {
        let d = temp_dir();
        let victim = d.join("victim");
        std::fs::write(&victim, "must survive").unwrap();
        let target = d.join("note.md");
        std::os::unix::fs::symlink(&victim, &target).unwrap();
        write_private_atomic(&target, b"note body").unwrap();
        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "must survive");
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "note body");
        assert!(!std::fs::symlink_metadata(&target).unwrap().file_type().is_symlink());
        assert_eq!(std::fs::metadata(&target).unwrap().permissions().mode() & 0o777, 0o600);
        assert!(std::fs::read_dir(&d).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().ends_with(".tmp")));
        // Never-replace refuses an existing file and a symlink alike.
        assert!(write_private_new(&target, b"x").is_err());
        let link = d.join("link.md");
        std::os::unix::fs::symlink(&victim, &link).unwrap();
        assert!(write_private_new(&link, b"x").is_err());
        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "must survive");
        write_private_new(&d.join("fresh.md"), b"fresh").unwrap();
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn owned_head_refuses_symlinks_fifos_and_others_files() {
        let d = temp_dir();
        let real = d.join("real");
        std::fs::write(&real, "0123456789").unwrap();
        assert_eq!(read_owned_head(&real, 4).unwrap(), b"0123");
        let link = d.join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert!(read_owned_head(&link, 4).is_none());
        let fifo = std::ffi::CString::new(d.join("fifo").to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        let t = Instant::now();
        assert!(read_owned_head(&d.join("fifo"), 4).is_none());
        assert!(t.elapsed() < Duration::from_secs(1), "a FIFO must not block");
        assert!(read_owned_head(&d.join("missing"), 4).is_none());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn private_dir_is_0700_and_never_a_symlink() {
        let d = temp_dir();
        let state = d.join("state");
        ensure_private_dir(&state).unwrap();
        assert_eq!(std::fs::metadata(&state).unwrap().permissions().mode() & 0o777, 0o700);
        std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o755)).unwrap();
        ensure_private_dir(&state).unwrap();
        assert_eq!(std::fs::metadata(&state).unwrap().permissions().mode() & 0o777, 0o700, "repaired");
        let link = d.join("linkdir");
        std::os::unix::fs::symlink(&state, &link).unwrap();
        assert!(ensure_private_dir(&link).is_err());
        let f = state.join("db");
        create_private_if_missing(&f).unwrap();
        std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o644)).unwrap();
        make_private(&f).unwrap();
        assert_eq!(std::fs::metadata(&f).unwrap().permissions().mode() & 0o777, 0o600);
        let _ = std::fs::remove_dir_all(&d);
    }
}
