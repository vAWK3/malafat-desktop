use tauri::Manager;
use tauri_plugin_notification::NotificationExt;
use tauri_plugin_store::StoreExt;

const STORE_FILE: &str = "settings.json";
const TENANT_SLUG_KEY: &str = "tenant_slug";

/// Show a native OS notification.
/// Called from the webview via Tauri IPC when a new in-app notification arrives.
#[tauri::command]
pub async fn show_native_notification(
    app: tauri::AppHandle,
    title: String,
    body: String,
    url: Option<String>,
) -> Result<(), String> {
    app.notification()
        .builder()
        .title(&title)
        .body(&body)
        .show()
        .map_err(|e| e.to_string())?;

    // Store the last notification URL. When the user clicks a notification
    // (which brings the app window to front), we navigate to this URL.
    // Tauri v2 notification click callbacks are platform-limited, so we
    // use the "bring to front + navigate" pattern instead.
    if let Some(click_url) = &url {
        if let Ok(store) = app.store(STORE_FILE) {
            store.set("pending_notification_url", serde_json::json!(click_url));
        }
    }

    Ok(())
}

/// Get the stored tenant slug, if any.
#[tauri::command]
pub async fn get_tenant_slug(app: tauri::AppHandle) -> Result<Option<String>, String> {
    let store = app.store(STORE_FILE).map_err(|e| e.to_string())?;
    let value = store.get(TENANT_SLUG_KEY);
    match value {
        Some(v) => Ok(v.as_str().map(|s| s.to_string())),
        None => Ok(None),
    }
}

/// Store the tenant slug for subsequent launches.
#[tauri::command]
pub async fn set_tenant_slug(app: tauri::AppHandle, slug: String) -> Result<(), String> {
    let slug = normalize_slug(&slug);
    if slug.is_empty() {
        return Err("Slug cannot be empty".to_string());
    }
    let store = app.store(STORE_FILE).map_err(|e| e.to_string())?;
    store.set(TENANT_SLUG_KEY, serde_json::json!(slug));
    store.save().map_err(|e| e.to_string())?;
    Ok(())
}

/// Clear the stored tenant slug (for "Switch Firm" action).
#[tauri::command]
pub async fn clear_tenant_slug(app: tauri::AppHandle) -> Result<(), String> {
    let store = app.store(STORE_FILE).map_err(|e| e.to_string())?;
    store.delete(TENANT_SLUG_KEY);
    store.save().map_err(|e| e.to_string())?;
    Ok(())
}

/// Set the dock badge count (macOS only).
#[tauri::command]
pub async fn set_badge_count(
    app: tauri::AppHandle,
    count: u32,
) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        // macOS dock badge - set via the main window
        if let Some(window) = app.get_webview_window("main") {
            if count > 0 {
                let _ = window.set_badge_count(Some(count as i64));
            } else {
                let _ = window.set_badge_count(None::<i64>);
            }
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        let _ = count;
        // Windows badge deferred to v2
    }

    Ok(())
}

/// Consume the pending notification URL (if any) and navigate to it.
/// Called from the webview when the window regains focus.
#[tauri::command]
pub async fn consume_pending_notification(app: tauri::AppHandle) -> Result<Option<String>, String> {
    let store = app.store(STORE_FILE).map_err(|e| e.to_string())?;
    let url = store.get("pending_notification_url")
        .and_then(|v| v.as_str().map(|s| s.to_string()));

    if url.is_some() {
        store.delete("pending_notification_url");
    }

    Ok(url)
}

/// Normalize a tenant slug input.
/// Accepts "acme" or "acme.malafat.app" and returns "acme".
fn normalize_slug(input: &str) -> String {
    let trimmed = input.trim().to_lowercase();
    // Strip protocol prefix first
    let without_protocol = trimmed
        .strip_prefix("https://")
        .or_else(|| trimmed.strip_prefix("http://"))
        .unwrap_or(&trimmed);
    // Strip .malafat.app suffix and any path after it
    if let Some(slug) = without_protocol.split(".malafat.app").next() {
        if slug != without_protocol {
            // Had the suffix, return the part before it
            return slug.to_string();
        }
    }
    // If it contains dots (e.g., "acme.malafat.app"), take first segment
    if without_protocol.contains('.') {
        without_protocol.split('.').next().unwrap_or("").to_string()
    } else {
        // Plain slug like "acme" or "my-law-firm"
        without_protocol.to_string()
    }
}

/// Check for updates (non-blocking, logs errors silently).
pub async fn check_for_updates(app: &tauri::AppHandle) {
    use tauri_plugin_updater::UpdaterExt;
    let updater = match app.updater() {
        Ok(u) => u,
        Err(e) => {
            eprintln!("Updater not available: {}", e);
            return;
        }
    };
    match updater.check().await {
        Ok(Some(update)) => {
            eprintln!(
                "Update available: {} -> {}",
                env!("CARGO_PKG_VERSION"),
                update.version
            );
            // Download and install in the background
            // On Windows: apply on next restart
            // On macOS: prompt user
            if let Err(e) = update.download_and_install(|_, _| {}, || {}).await {
                eprintln!("Failed to install update: {}", e);
            }
        }
        Ok(None) => {
            // No update available
        }
        Err(e) => {
            eprintln!("Update check failed: {}", e);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_slug_plain() {
        assert_eq!(normalize_slug("acme"), "acme");
    }

    #[test]
    fn test_normalize_slug_with_suffix() {
        assert_eq!(normalize_slug("acme.malafat.app"), "acme");
    }

    #[test]
    fn test_normalize_slug_with_https() {
        assert_eq!(normalize_slug("https://acme.malafat.app"), "acme");
    }

    #[test]
    fn test_normalize_slug_with_http() {
        assert_eq!(normalize_slug("http://acme.malafat.app"), "acme");
    }

    #[test]
    fn test_normalize_slug_trims_whitespace() {
        assert_eq!(normalize_slug("  Acme  "), "acme");
    }

    #[test]
    fn test_normalize_slug_lowercase() {
        assert_eq!(normalize_slug("ACME"), "acme");
    }

    #[test]
    fn test_normalize_slug_empty_returns_empty() {
        assert_eq!(normalize_slug(""), "");
    }

    #[test]
    fn test_normalize_slug_with_hyphens() {
        assert_eq!(normalize_slug("my-law-firm"), "my-law-firm");
    }

    #[test]
    fn test_normalize_slug_full_url_with_path() {
        assert_eq!(normalize_slug("https://acme.malafat.app/admin"), "acme");
    }
}
