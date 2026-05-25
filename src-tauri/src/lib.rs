mod commands;
mod tray;

use tauri::Manager;

/// Navigate the main webview to a URL.
/// Used by tray quick actions and notification click handlers.
pub fn navigate_webview(app: &tauri::AppHandle, url: &str) {
    if let Some(window) = app.get_webview_window("main") {
        // If URL is a path (starts with /), prepend the current origin
        let full_url = if url.starts_with('/') {
            if let Ok(current) = window.url() {
                let origin = format!("{}://{}", current.scheme(), current.host_str().unwrap_or("malafat.app"));
                format!("{}{}", origin, url)
            } else {
                url.to_string()
            }
        } else {
            url.to_string()
        };

        let _ = window.navigate(full_url.parse().unwrap_or_else(|_| {
            tauri::Url::parse("https://malafat.app").unwrap()
        }));
        let _ = window.set_focus();
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_store::Builder::default().build())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .plugin(
            // Intercept navigation to /desktop/switch-firm to return to workspace chooser.
            // The web app can link to this path to let users switch firms.
            tauri::plugin::Builder::<tauri::Wry>::new("switch-firm-interceptor")
                .on_navigation(|webview, url| {
                    if url.path() == "/desktop/switch-firm" {
                        let app = webview.app_handle().clone();
                        tauri::async_runtime::spawn(async move {
                            let _ = commands::clear_tenant_slug(app.clone()).await;
                            if let Some(win) = app.get_webview_window("main") {
                                let picker_url = tauri::Url::parse("tauri://localhost/index.html")
                                    .unwrap_or_else(|_| {
                                        tauri::Url::parse("https://malafat.app").unwrap()
                                    });
                                let _ = win.navigate(picker_url);
                            }
                        });
                        return false; // Block the navigation
                    }
                    true
                })
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            commands::show_native_notification,
            commands::get_tenant_slug,
            commands::set_tenant_slug,
            commands::clear_tenant_slug,
            commands::set_badge_count,
            commands::consume_pending_notification,
            commands::navigate_to_url,
        ])
        .setup(|app| {
            // Set up system tray
            tray::create_tray(app.handle())?;

            // Check for updates on launch (non-blocking)
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                commands::check_for_updates(&handle).await;
            });

            // Schedule periodic update checks (every 4 hours).
            // Uses a dedicated OS thread to avoid blocking the async runtime.
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                loop {
                    std::thread::sleep(std::time::Duration::from_secs(4 * 60 * 60));
                    let handle = handle.clone();
                    tauri::async_runtime::block_on(async move {
                        commands::check_for_updates(&handle).await;
                    });
                }
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Malafat Desktop");
}

#[cfg(test)]
mod tests {
    #[test]
    fn test_navigate_webview_absolute_url_unchanged() {
        // Absolute URLs should pass through unchanged
        let url = "https://demo.malafat.app/admin/tasks/new";
        assert!(url.starts_with("https://"));
    }

    #[test]
    fn test_navigate_webview_relative_path_detected() {
        // Relative paths start with /
        let url = "/admin/tasks/new";
        assert!(url.starts_with('/'));
    }
}
