# Interactive editing

Run `habush --config examples/config.zon` to try the keybinding example.
Editing is enabled automatically on supported POSIX terminals; Windows still
uses cooked line input.

| Key | Default action |
| --- | --- |
| Up / Down | Ordinary history on single-line input, line movement in multiline input; select candidates while a menu is open |
| Ctrl+P / Ctrl+N | Previous/next history entry, including during multiline editing |
| Ctrl+L | Clear the visible screen and redraw the current input, preserving the cursor and Undo |
| Tab, Shift+Tab | Complete or move forward/backward through candidates |
| Enter | Insert the selected candidate; otherwise add a continuation newline for incomplete syntax or submit the whole input |
| Ctrl+O | Insert a newline without submitting |
| Escape | Dismiss the menu |
| Ctrl+A/E, Ctrl+B/F | Start/end, previous/next character |
| Ctrl+K/U | Delete to end/start |
| Ctrl+_ | Undo the last edit |
| Ctrl+C, Ctrl+D | Cancel input, or EOF/delete |

History contains submitted source, including compound commands and here-documents.
Returning past the newest entry restores the draft and its cursor. Consecutive
duplicates and blank input are omitted. It retains at most 1000 entries and
1 MiB in this process; inputs over the editor's 64 KiB limit are omitted.
History is not saved to disk. Continuation and here-document text stay in the
same editable input. Arrows move between logical lines using Unicode scalar
columns; Ctrl+A/E and Ctrl+U/K operate on the current line. Long lines scroll
horizontally and long inputs use a vertical viewport. Menus are repainted below
the input instead of being appended to scrollback on every selection.

The ZON `keybinds` list maps `key` to `action`. Named keys are `up`, `down`,
`left`, `right`, `home`, `end`, `delete`, `backtab`, `enter`, `tab`, `backspace`,
`escape`, and `space`. Single printable ASCII keys and `ctrl+<letter>` are also
supported, including `ctrl+space` and `ctrl+_`. Terminal aliases normalize to
the same key: Ctrl+I/Tab, Ctrl+J/Ctrl+M/Enter, Ctrl+H/Backspace.

Later bindings override earlier ones and defaults. `ignore` consumes the key;
`unbind` removes the action, leaving printable keys as text and ringing the bell
for other unhandled keys. Invalid triggers/actions fail configuration loading.
See [the action enum](../src/lib/edit/Keybind.zig) for available actions.

The trigger/action separation and override order follow the approach in
[Ghostty's keybinding documentation](https://ghostty.org/docs/config/keybind).
This terminal editor does not implement Ghostty's GUI/global keys or key sequences.
The `complete` action uses the existing application-supplied completion service;
it grants no new permissions to plugins. See [plugin examples](plugins/README.md).

`prompt.spans` configures literal text with optional `style.foreground`,
`style.background` (`default`, black, red, green, yellow, blue, magenta, cyan,
white) and `style.bold`. Prompts are clipped to terminal width; control bytes
are displayed visibly. ANSI and OSC in text are never executed. Embedders can
also supply an `edit.Prompt.Provider`, receiving cwd/status and allocating the
result in the caller's arena. An unavailable or invalid result uses the configured
prompt. The provider runs once before collecting an input, including continuation
lines, and does not change the Session's status.

Syntax diagnostics underline input ranges and show bounded messages below the
input, without evaluating source or changing the exit status. Set `.diagnostics =
false` in config.zon to disable them. Embedders can supply an `edit.Diagnostic.Provider`;
results must match the input revision and contain valid byte ranges. Messages are
literal display text. Old results disappear on editing; failed/invalid additional
providers leave native syntax diagnostics available. This is an advisory display,
not an execution policy.
