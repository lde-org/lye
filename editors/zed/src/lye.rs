use zed_extension_api::{self as zed, Command, LanguageServerId, Result, Worktree};

/// The lye language server: it is the whole extension. There is no grammar to provide, because Zed
/// already highlights Lua, and nothing to configure, because the server reads its own settings.
struct LyeExtension;

impl LyeExtension {
    /// Where the server is. A binary the user installed is used as it is; the extension does not
    /// bundle one, so the version of lye that runs is the one the user has.
    fn server_path(worktree: &Worktree) -> Result<String> {
        match worktree.which("lye-lsp") {
            Some(path) => Ok(path),
            None => Err(
                "lye-lsp was not found on PATH. Install lye so that `lye-lsp` is on your PATH, \
                 or point Zed at it with `lsp.lye-lsp.binary.path` in your settings."
                    .to_string(),
            ),
        }
    }
}

impl zed::Extension for LyeExtension {
    fn new() -> Self {
        Self
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &LanguageServerId,
        worktree: &Worktree,
    ) -> Result<Command> {
        let path = Self::server_path(worktree)?;
        Ok(Command {
            command: path,
            // The same flag the VS Code client passes: speak the protocol over stdio.
            args: vec!["--stdio".to_string()],
            env: Default::default(),
        })
    }
}

zed::register_extension!(LyeExtension);
