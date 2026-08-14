use rand::Rng;
use std::env;
use std::error::Error;
use std::fs;
use std::io;
use std::net::TcpListener;
use std::path::Path;
use std::sync::Mutex;
use tauri::async_runtime::spawn;
use tauri::Manager;
use tauri::RunEvent;
use tauri::State;
use tauri_plugin_shell::process::CommandChild;
use tauri_plugin_shell::ShellExt;
use tokio::time::{sleep, Duration};
use url::Url;

struct AppData {
    port: u16,
    webserver_child: Option<CommandChild>,
}

const OLD_IDENTIFIER: &str = "app.melocoton.app";

#[tauri::command]
fn open_new_window(app_handle: tauri::AppHandle, state: State<'_, Mutex<AppData>>) {
    let port = state.lock().unwrap().port;
    let raw_url = format!("http://localhost:{}", port);

    let _webview_window = tauri::WebviewWindowBuilder::new(
        &app_handle,
        // we need to have a
        // unique application
        // label so we use a
        // random string
        generate_secret_key(10),
        tauri::WebviewUrl::App((raw_url).into()),
    )
    .title("Melocoton")
    .build()
    .unwrap();
}

fn get_available_port() -> Result<u16, Box<dyn Error>> {
    // Port 0 tells the OS to assign an available ephemeral port.
    let listener = TcpListener::bind("0.0.0.0:0")?;

    let addr = listener.local_addr()?;

    // We don't need the listener anymore, so close it.
    drop(listener);

    Ok(addr.port())
}

fn generate_secret_key(length: usize) -> String {
    const CHARSET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    let mut rng = rand::rng();
    let random_string: String = (0..length)
        .map(|_| {
            let idx = rng.random_range(0..CHARSET.len());
            CHARSET[idx] as char
        })
        .collect();
    random_string
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    tauri::Builder::default()
        .setup(|app| {
            let port = get_available_port()?;

            app.manage(Mutex::new(AppData {
                port,
                webserver_child: None,
            }));

            println!("Running web application on port: {}", port);

            spawn(setup(app.handle().clone(), port));

            Ok(())
        })
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![open_new_window])
        .build(tauri::generate_context!())?
        .run(|app, event| {
            if let RunEvent::Exit = event {
                let child = app
                    .state::<Mutex<AppData>>()
                    .lock()
                    .unwrap()
                    .webserver_child
                    .take();

                if let Some(child) = child {
                    shutdown_webserver(child);
                }
            }
        });

    Ok(())
}

async fn is_http_ready(address: &str, timeout_seconds: u64) -> bool {
    let client = reqwest::Client::new();
    let start_time = std::time::Instant::now();

    while start_time.elapsed() < Duration::from_secs(timeout_seconds) {
        match client.get(address).send().await {
            Ok(response) if response.status().is_success() => {
                println!("HTTP server is ready!");
                return true;
            }
            Ok(response) => {
                println!(
                    "Received status: {} from {}, waiting...",
                    response.status(),
                    address
                );
            }
            Err(e) => {
                println!("Error connecting to {}: {}, retrying...", address, e);
            }
        }
        sleep(Duration::from_millis(500)).await;
    }

    println!("Timeout reached, HTTP server not ready.");
    false
}

fn migrate_app_data(new_dir: &Path) -> io::Result<()> {
    let Some(data_root) = new_dir.parent() else {
        return Ok(());
    };
    let old_dir = data_root.join(OLD_IDENTIFIER);

    if !old_dir.is_dir() {
        return Ok(());
    }

    println!(
        "Migrating application data from {} to {}",
        old_dir.display(),
        new_dir.display()
    );
    copy_missing_files(&old_dir, new_dir)
}

fn copy_missing_files(source: &Path, destination: &Path) -> io::Result<()> {
    fs::create_dir_all(destination)?;

    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let source_path = entry.path();
        let destination_path = destination.join(entry.file_name());
        let file_type = entry.file_type()?;

        if file_type.is_dir() {
            copy_missing_files(&source_path, &destination_path)?;
        } else if file_type.is_file() && !destination_path.exists() {
            fs::copy(source_path, destination_path)?;
        }
    }

    Ok(())
}

async fn setup(
    app_handle: tauri::AppHandle,
    port: u16,
) -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let base_dir = app_handle.path().app_data_dir()?;
    migrate_app_data(&base_dir)?;

    let database_path = base_dir.join(Path::new("melocoton.db"));

    env::set_var("DATABASE_PATH", database_path);
    env::set_var("SECRET_KEY_BASE", generate_secret_key(64));
    env::set_var("PHX_SERVER", "1");
    env::set_var("PHX_HOST", "localhost");
    env::set_var("PORT", port.to_string());

    // BEAM memory optimizations for desktop sidecar
    env::set_var("RELEASE_DISTRIBUTION", "none"); // no clustering needed
    env::set_var("RELEASE_MODE", "interactive"); // load modules on demand

    // start web server
    let (_receiver, child) = app_handle.shell().sidecar("webserver")?.spawn()?;

    app_handle
        .state::<Mutex<AppData>>()
        .lock()
        .unwrap()
        .webserver_child = Some(child);

    let raw_url = format!("http://localhost:{}", port);
    let timeout = 10;

    if is_http_ready(&raw_url, timeout).await {
        let webview = app_handle.get_webview_window("main").unwrap();
        let url = Url::parse(&raw_url)?;

        let _ = webview.navigate(url);
    }

    Ok(())
}

fn shutdown_webserver(child: CommandChild) {
    let pid = child.pid();
    println!("Shutting down web server (pid {pid})...");

    terminate_process_tree(pid);

    // Kill the wrapper again through the handle so its exit status is reaped.
    let _ = child.kill();
}

/// Terminates `pid` together with all of its descendants.
///
/// The webserver sidecar is a Burrito-wrapped release: the wrapper spawns the
/// actual BEAM (`beam.smp`) as a child process, so killing only the wrapper
/// would orphan the BEAM. Descendants are killed before their parents to
/// prevent them from being re-parented (and thus missed) mid-walk.
fn terminate_process_tree(pid: u32) {
    #[cfg(windows)]
    {
        // `taskkill /T` walks and terminates the whole process tree.
        let _ = std::process::Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/T", "/F"])
            .status();
    }

    #[cfg(unix)]
    {
        let mut pids = vec![pid];
        let mut stack = vec![pid];

        while let Some(parent) = stack.pop() {
            for child in child_pids(parent) {
                stack.push(child);
                pids.push(child);
            }
        }

        for pid in pids.iter().rev() {
            unsafe {
                libc::kill(*pid as libc::pid_t, libc::SIGKILL);
            }
        }
    }
}

/// Returns the direct children of `parent`.
#[cfg(target_os = "linux")]
fn child_pids(parent: u32) -> Vec<u32> {
    let mut children = Vec::new();

    let Ok(tasks) = std::fs::read_dir(format!("/proc/{parent}/task")) else {
        return children;
    };

    for task in tasks.flatten() {
        if let Ok(contents) = std::fs::read_to_string(task.path().join("children")) {
            children.extend(
                contents
                    .split_whitespace()
                    .filter_map(|pid| pid.parse::<u32>().ok()),
            );
        }
    }

    children
}

/// Returns the direct children of `parent`.
#[cfg(all(unix, not(target_os = "linux")))]
fn child_pids(parent: u32) -> Vec<u32> {
    std::process::Command::new("pgrep")
        .args(["-P", &parent.to_string()])
        .output()
        .map(|output| {
            String::from_utf8_lossy(&output.stdout)
                .split_whitespace()
                .filter_map(|pid| pid.parse::<u32>().ok())
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temporary_directory(name: &str) -> PathBuf {
        env::temp_dir().join(format!(
            "melocoton-{name}-{}-{}",
            std::process::id(),
            generate_secret_key(8)
        ))
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn webserver_sidecar_is_terminated_when_the_app_shuts_down() {
        use std::process::Command;

        // Stand-in for the burrito-wrapped webserver sidecar: a wrapper that
        // spawns a long-lived child process (beam.smp in the real release)
        // and waits on it.
        let mut stand_in = Command::new("sh")
            .arg("-c")
            .arg("sleep 300 & wait")
            .spawn()
            .unwrap();
        let wrapper_pid = stand_in.id();

        // Wait (bounded) until the wrapper has spawned its child.
        let mut child_pid = None;
        for _ in 0..100 {
            if let Some(pid) = child_pids(wrapper_pid).first().copied() {
                child_pid = Some(pid);
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let child_pid = child_pid.expect("webserver stand-in never spawned its child process");

        // Same shutdown path the app runs on RunEvent::Exit.
        terminate_process_tree(wrapper_pid);

        // Reap the wrapper so it does not linger as a zombie.
        stand_in.wait().unwrap();

        // Killing is asynchronous; wait (bounded) for both processes to die.
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while (process_alive(wrapper_pid) || process_alive(child_pid))
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(50));
        }

        let wrapper_alive = process_alive(wrapper_pid);
        let child_alive = process_alive(child_pid);

        // Cleanup so a failing assertion doesn't leak processes.
        for pid in [wrapper_pid, child_pid] {
            let _ = Command::new("kill").arg("-9").arg(pid.to_string()).status();
        }

        assert!(
            !wrapper_alive,
            "webserver sidecar (pid {wrapper_pid}) survived app shutdown"
        );
        assert!(
            !child_alive,
            "webserver child process, i.e. beam (pid {child_pid}) survived app shutdown"
        );
    }

    #[cfg(target_os = "linux")]
    fn process_alive(pid: u32) -> bool {
        std::path::Path::new(&format!("/proc/{pid}")).exists()
    }

    #[test]
    fn migrates_old_app_data_without_overwriting_new_files() {
        let root = temporary_directory("migration");
        let old_dir = root.join(OLD_IDENTIFIER);
        let new_dir = root.join("com.ruaylabs.melocoton");
        fs::create_dir_all(old_dir.join("nested")).unwrap();
        fs::create_dir_all(&new_dir).unwrap();
        fs::write(old_dir.join("melocoton.db"), "old database").unwrap();
        fs::write(old_dir.join("nested/settings.json"), "settings").unwrap();
        fs::write(new_dir.join("melocoton.db"), "new database").unwrap();

        migrate_app_data(&new_dir).unwrap();

        assert_eq!(
            fs::read_to_string(new_dir.join("melocoton.db")).unwrap(),
            "new database"
        );
        assert_eq!(
            fs::read_to_string(new_dir.join("nested/settings.json")).unwrap(),
            "settings"
        );

        fs::remove_dir_all(root).unwrap();
    }
}
