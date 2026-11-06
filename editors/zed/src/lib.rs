//! nedls in Zed: starts ned's language server for Nim files (the Nim extension gives Zed the language itself) and
//! passes it the settings under `lsp.nedls` in Zed's settings. The program is the one `lsp.nedls.binary.path`
//! names, else `nedls` on the PATH of the project's shell; it is never downloaded.

use zed_extension_api::{self as zed, settings::LspSettings, LanguageServerId, Result};

struct Nedls;

impl Nedls {
    // `lsp.nedls` in Zed's settings for this project (none: the defaults)
    fn settings(id: &LanguageServerId, worktree: &zed::Worktree) -> LspSettings {
        LspSettings::for_worktree(id.as_ref(), worktree).unwrap_or_default()
    }
}

impl zed::Extension for Nedls {
    fn new() -> Self {
        Nedls
    }

    fn language_server_command(
        &mut self,
        id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<zed::Command> {
        let binary = Self::settings(id, worktree).binary;
        let mut env = worktree.shell_env();
        let mut args = vec!["--stdio".to_string()];
        let mut path = None;
        if let Some(b) = binary {
            path = b.path;
            if let Some(a) = b.arguments {
                args = a;
            }
            if let Some(e) = b.env {
                env.extend(e);
            }
        }
        let command = path.or_else(|| worktree.which("nedls")).ok_or_else(|| {
            "nedls is not on PATH: `nimble install https://github.com/foxoman/ned` builds it (with ned and nedfmt, \
             into ~/.nimble/bin), or name it in Zed's settings: \
             \"lsp\": {\"nedls\": {\"binary\": {\"path\": \"/path/to/nedls\"}}}"
                .to_string()
        })?;
        Ok(zed::Command { command, args, env })
    }

    // (read when nedls starts: `lsp.nedls.initialization_options`)
    fn language_server_initialization_options(
        &mut self,
        id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<Option<zed::serde_json::Value>> {
        Ok(Self::settings(id, worktree).initialization_options)
    }

    // (what nedls asks for — the section "nedls" — and is sent again when they change: `lsp.nedls.settings`)
    fn language_server_workspace_configuration(
        &mut self,
        id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<Option<zed::serde_json::Value>> {
        let settings = Self::settings(id, worktree)
            .settings
            .unwrap_or_else(|| zed::serde_json::json!({}));
        Ok(Some(zed::serde_json::json!({ "nedls": settings })))
    }
}

zed::register_extension!(Nedls);
