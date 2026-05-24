use tauri::{
    menu::{MenuBuilder, MenuItemBuilder, PredefinedMenuItem},
    tray::TrayIconBuilder,
    Manager,
};

/// Menu item IDs for the system tray context menu.
const OPEN: &str = "open";
const NEW_TASK: &str = "new_task";
const LOG_TIME: &str = "log_time";
const SWITCH_FIRM: &str = "switch_firm";
const CHECK_UPDATES: &str = "check_updates";
const QUIT: &str = "quit";

/// Create the system tray with context menu.
pub fn create_tray(app: &tauri::AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let open = MenuItemBuilder::with_id(OPEN, "Open Malafat").build(app)?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let new_task = MenuItemBuilder::with_id(NEW_TASK, "New Task").build(app)?;
    let log_time = MenuItemBuilder::with_id(LOG_TIME, "Log Time").build(app)?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    let switch_firm = MenuItemBuilder::with_id(SWITCH_FIRM, "Switch Firm").build(app)?;
    let check_updates = MenuItemBuilder::with_id(CHECK_UPDATES, "Check for Updates").build(app)?;
    let quit = MenuItemBuilder::with_id(QUIT, "Quit Malafat").build(app)?;

    let menu = MenuBuilder::new(app)
        .item(&open)
        .item(&sep1)
        .item(&new_task)
        .item(&log_time)
        .item(&sep2)
        .item(&switch_firm)
        .item(&check_updates)
        .item(&quit)
        .build()?;

    TrayIconBuilder::new()
        .menu(&menu)
        .tooltip("Malafat")
        .on_menu_event(move |app, event| {
            handle_menu_event(app, event.id().as_ref());
        })
        .on_tray_icon_event(|tray, event| {
            if let tauri::tray::TrayIconEvent::Click {
                button: tauri::tray::MouseButton::Left,
                button_state: tauri::tray::MouseButtonState::Up,
                ..
            } = event
            {
                let app = tray.app_handle();
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
        })
        .build(app)?;

    Ok(())
}

/// Handle tray menu item clicks.
fn handle_menu_event(app: &tauri::AppHandle, menu_id: &str) {
    match menu_id {
        OPEN => {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.set_focus();
            }
        }
        NEW_TASK => {
            crate::navigate_webview(app, "/admin/tasks/new");
        }
        LOG_TIME => {
            crate::navigate_webview(app, "/admin/time");
        }
        SWITCH_FIRM => {
            // Clear stored slug and navigate back to the bundled tenant picker
            let app_clone = app.clone();
            tauri::async_runtime::spawn(async move {
                let _ = crate::commands::clear_tenant_slug(app_clone.clone()).await;
                if let Some(window) = app_clone.get_webview_window("main") {
                    // Use the Tauri asset protocol URL (works in both dev and bundled builds)
                    let url = tauri::Url::parse("tauri://localhost/index.html")
                        .unwrap_or_else(|_| tauri::Url::parse("https://malafat.app").unwrap());
                    let _ = window.navigate(url);
                }
            });
        }
        CHECK_UPDATES => {
            let app_clone = app.clone();
            tauri::async_runtime::spawn(async move {
                crate::commands::check_for_updates(&app_clone).await;
            });
        }
        QUIT => {
            app.exit(0);
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_menu_ids_are_unique() {
        let ids = [OPEN, NEW_TASK, LOG_TIME, SWITCH_FIRM, CHECK_UPDATES, QUIT];
        let unique: std::collections::HashSet<_> = ids.iter().collect();
        assert_eq!(ids.len(), unique.len(), "Menu IDs must be unique");
    }

    #[test]
    fn test_menu_ids_are_non_empty() {
        let ids = [OPEN, NEW_TASK, LOG_TIME, SWITCH_FIRM, CHECK_UPDATES, QUIT];
        for id in ids {
            assert!(!id.is_empty(), "Menu ID must not be empty");
        }
    }
}
